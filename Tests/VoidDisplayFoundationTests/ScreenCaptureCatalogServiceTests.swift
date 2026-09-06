@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing

private actor SequencedCatalogServiceLoadGate {
    enum Outcome: Sendable {
        case success
        case failure(any Error)
    }

    private struct PendingCall {
        let outcome: Outcome
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private let scriptedOutcomes: [Outcome]
    private var callCount = 0
    private var pendingCalls: [Int: PendingCall] = [:]

    init(scriptedOutcomes: [Outcome]) {
        self.scriptedOutcomes = scriptedOutcomes
    }

    func nextOutcome() async -> Outcome {
        callCount += 1
        let callIndex = callCount
        let outcome = scriptedOutcomes.indices.contains(callIndex - 1)
            ? scriptedOutcomes[callIndex - 1]
            : .success
        return await withCheckedContinuation { continuation in
            pendingCalls[callIndex] = PendingCall(outcome: outcome, continuation: continuation)
        }
    }

    func release(call callIndex: Int) {
        guard let pending = pendingCalls.removeValue(forKey: callIndex) else { return }
        pending.continuation.resume(returning: pending.outcome)
    }

    func currentCallCount() -> Int {
        callCount
    }
}

private struct CatalogServiceControlledFailure: Error, Sendable {}

private actor CatalogServiceAsyncCallFlag {
    private var value = false

    func markCalled() {
        value = true
    }

    func wasCalled() -> Bool {
        value
    }
}

@MainActor
private final class CatalogServiceSignatureBox {
    var value: ScreenCaptureDisplayTopologySignature

    init(_ value: ScreenCaptureDisplayTopologySignature) {
        self.value = value
    }
}

@MainActor
@Suite(.serialized)
struct ScreenCaptureCatalogServiceTests {
    @Test func defaultShareableDisplayLoaderReturnsEmptySnapshotUnderXCTestEnvironment() async throws {
        let loader = ScreenCaptureShareableDisplayLoaderFactory.makeDefault(
            environment: [
                PersistenceContext.xCTestConfigurationEnvironmentKey: "/tmp/VoidDisplayTests.xctest"
            ]
        )

        let displays = try await loader()

        #expect(displays.isEmpty)
    }

    @Test func defaultShareableDisplayLoaderUsesFixtureDisplaysUnderUITestMode() async throws {
        let loader = ScreenCaptureShareableDisplayLoaderFactory.makeDefault(
            environment: [
                UITestRuntime.modeEnvironmentKey: "1",
                UITestRuntime.scenarioEnvironmentKey: UITestScenario.baseline.rawValue
            ]
        )

        let displays = try await loader()

        #expect(!displays.isEmpty)
    }

    @Test func requestPermissionDeniedUpdatesCatalogState() {
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: false, requestResult: false),
            loadShareableDisplays: { [] },
            activeDisplayIDsProvider: { [] }
        )

        let granted = sut.requestPermission()

        #expect(granted == false)
        #expect(sut.store.hasScreenCapturePermission == false)
        #expect(sut.store.lastRequestPermission == false)
        #expect(sut.store.lastPreflightPermission == false)
    }

    @Test func catalogSnapshotExposesOnlyActiveShareableDisplays() {
        let hiddenDisplay = SharedMockSCDisplay.make(displayID: 91, width: 1920, height: 1080)
        let activeDisplay = SharedMockSCDisplay.make(displayID: 92, width: 2560, height: 1440)
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [] },
            activeDisplayIDsProvider: { [activeDisplay.displayID] }
        )
        sut.store.displays = [hiddenDisplay, activeDisplay]
        sut.store.lastLoadedActiveDisplayTopologySignature = sut.currentActiveDisplayTopologySignature()

        let snapshot = sut.makeCatalogStateSnapshot()

        #expect(sut.store.activeShareableDisplays?.map(\.displayID) == [activeDisplay.displayID])
        #expect(snapshot.loadedDisplays == [
            .init(displayID: activeDisplay.displayID, pixelWidth: 2560, pixelHeight: 1440)
        ])
    }

    @Test func refreshFailurePersistsErrorDetails() async {
        let expected = NSError(domain: "CatalogTests", code: 42)
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { throw expected },
            activeDisplayIDsProvider: { [101] }
        )
        sut.store.hasScreenCapturePermission = true

        let result = await sut.submitRefresh(intent: .userForcedRefresh)

        #expect(result.result == .failed)
        #expect(sut.store.isLoadingDisplays == false)
        #expect(sut.store.loadErrorMessage != nil)
        #expect(sut.store.lastLoadError?.domain == expected.domain)
        #expect(sut.store.lastLoadError?.code == expected.code)
        #expect(sut.store.displays == nil)
    }

    @Test func cancelledRefreshCancelsLoaderSleepWithoutPublishingDisplays() async throws {
        let clock = ManualTestClock()
        var loaderCompleted = false
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                try await clock.sleep(for: .seconds(3))
                loaderCompleted = true
                return []
            },
            activeDisplayIDsProvider: { [] }
        )
        let refresh = Task { await sut.submitRefresh(intent: .userForcedRefresh) }
        defer {
            refresh.cancel()
            clock.advance(by: .seconds(3))
        }
        try #require(await waitUntil { clock.pendingSleepCount == 1 && sut.store.isLoadingDisplays })

        let cleared = await sut.clearSnapshotForDeniedPermission()

        #expect(await waitUntil { clock.pendingSleepCount == 0 })
        #expect(await refresh.value == cleared)
        #expect(!loaderCompleted)
        #expect(!sut.store.isLoadingDisplays)
        #expect(sut.store.displays == nil)
    }

    @Test func unchangedTopologyReusesSnapshotWithoutReload() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success])
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [101] }
        )
        sut.store.hasScreenCapturePermission = true
        sut.store.displays = []
        sut.store.lastLoadedActiveDisplayTopologySignature = makeTestDisplayTopologySignature([101])

        let result = await sut.submitRefresh(intent: .permissionChanged)

        #expect(result.result == .reusedSnapshot)
        #expect(sut.store.lastRefreshResult == .reusedSnapshot)
        #expect(await gate.currentCallCount() == 0)
    }

    @Test func snapshotPublishedDuringRefreshRemainsAvailableUntilLoadCompletes() async {
        let store = ScreenCaptureCatalogStore()
        let display = SharedMockSCDisplay.make(displayID: 707, width: 1920, height: 1080)
        let signature = makeTestDisplayTopologySignature([707])
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success])
        let sut = ScreenCaptureCatalogService(
            store: store,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                // Publish a snapshot after refresh starts, before its load completes.
                #expect(store.displays == nil)
                store.displays = [display]
                store.lastLoadedActiveDisplayTopologySignature = signature
                switch await gate.nextOutcome() {
                case .success: return [display]
                case .failure(let error): throw error
                }
            },
            activeDisplayIDsProvider: { [707] },
            displayTopologySignatureProvider: { signature }
        )

        let refresh = Task { await sut.submitRefresh(intent: .permissionChanged) }
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(await eventually(timeoutNanoseconds: 1_000_000_000) { await store.isLoadingDisplays })
        #expect(store.activeShareableDisplays?.map(\.displayID) == [707])
        await gate.release(call: 1)
        #expect(await refresh.value.result == .reloadedSnapshot)
        #expect(store.activeShareableDisplays?.map(\.displayID) == [707])
    }

    @Test func permissionDeniedClearsSnapshot() async {
        let callFlag = CatalogServiceAsyncCallFlag()
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: false, requestResult: false),
            loadShareableDisplays: {
                await callFlag.markCalled()
                return []
            },
            activeDisplayIDsProvider: { [202] }
        )
        sut.store.displays = []
        sut.store.hasScreenCapturePermission = true

        let result = await sut.submitRefresh(intent: .permissionChanged)

        #expect(result.result == .clearedSnapshot)
        #expect(await callFlag.wasCalled() == false)
        #expect(sut.store.lastPreflightPermission == false)
        #expect(sut.store.isLoadingDisplays == false)
        #expect(sut.store.displays == nil)
        #expect(sut.store.hasScreenCapturePermission == false)
        #expect(sut.store.lastRefreshResult == .clearedSnapshot)
    }

    @Test func supersededRefreshReturnsReplacementOutcomeWithoutOverwritingLatestSnapshot() async {
        let gate = SequencedCatalogServiceLoadGate(
            scriptedOutcomes: [
                .failure(CatalogServiceControlledFailure()),
                .success
            ]
        )
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [303] }
        )
        sut.store.hasScreenCapturePermission = true

        let firstRefresh = Task { await sut.submitRefresh(intent: .permissionChanged) }
        #expect(await waitForLoaderCall(gate, count: 1))

        let secondRefresh = Task { await sut.submitRefresh(intent: .userForcedRefresh) }
        #expect(await waitForLoaderCall(gate, count: 2))

        await gate.release(call: 2)
        #expect(await secondRefresh.value.result == .reloadedSnapshot)
        #expect(sut.store.displays?.isEmpty == true)
        #expect(sut.store.lastLoadError == nil)

        await gate.release(call: 1)
        #expect(await firstRefresh.value.result == .reloadedSnapshot)
        #expect(sut.store.displays?.isEmpty == true)
        #expect(sut.store.lastLoadError == nil)
        #expect(sut.store.lastRefreshResult == .reloadedSnapshot)
    }

    @Test func supersededRefreshWaitsForReplacementWithoutClearingLoadingState() async {
        let gate = SequencedCatalogServiceLoadGate(
            scriptedOutcomes: [
                .failure(CatalogServiceControlledFailure()),
                .success
            ]
        )
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [505] }
        )
        sut.store.hasScreenCapturePermission = true

        let firstRefresh = Task { await sut.submitRefresh(intent: .permissionChanged) }
        #expect(await waitForLoaderCall(gate, count: 1))

        let secondRefresh = Task { await sut.submitRefresh(intent: .userForcedRefresh) }
        #expect(await waitForLoaderCall(gate, count: 2))
        #expect(sut.store.isLoadingDisplays == true)

        await gate.release(call: 1)

        #expect(sut.store.isLoadingDisplays == true)
        #expect(sut.store.lastLoadError == nil)
        #expect(sut.store.lastRefreshResult == nil)

        await gate.release(call: 2)

        #expect(await secondRefresh.value.result == .reloadedSnapshot)
        #expect(await firstRefresh.value.result == .reloadedSnapshot)
        #expect(sut.store.isLoadingDisplays == false)
        #expect(sut.store.lastRefreshResult == .reloadedSnapshot)
    }

    @Test func supersededRefreshReturnsWhenReplacementSettlesEvenIfCancelledLoaderDoesNotReturn() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success, .success])
        let firstRefreshCompleted = CatalogServiceAsyncCallFlag()
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [506] }
        )
        sut.store.hasScreenCapturePermission = true

        let firstRefresh = Task {
            let result = await sut.submitRefresh(intent: .permissionChanged)
            await firstRefreshCompleted.markCalled()
            return result
        }
        #expect(await waitForLoaderCall(gate, count: 1))

        let replacementRefresh = Task {
            await sut.submitRefresh(intent: .userForcedRefresh)
        }
        #expect(await waitForLoaderCall(gate, count: 2))

        await gate.release(call: 2)
        #expect(await replacementRefresh.value.result == .reloadedSnapshot)
        #expect(await eventually(timeoutNanoseconds: 250_000_000) {
            await firstRefreshCompleted.wasCalled()
        })

        await gate.release(call: 1)
        #expect(await firstRefresh.value.result == .reloadedSnapshot)
    }

    @Test func matchingCachedTopologyJoinsInFlightRefreshInsteadOfReusingStaleSnapshot() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success])
        let staleDisplay = SharedMockSCDisplay.make(displayID: 707, width: 1280, height: 720)
        let refreshedDisplay = SharedMockSCDisplay.make(displayID: 808, width: 1920, height: 1080)
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return [refreshedDisplay]
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [707] }
        )
        sut.store.hasScreenCapturePermission = true
        sut.store.displays = [staleDisplay]
        sut.store.lastLoadedActiveDisplayTopologySignature = makeTestDisplayTopologySignature([707])

        let firstRefresh = Task {
            await sut.submitRefresh(intent: .userForcedRefresh)
        }
        #expect(await waitForLoaderCall(gate, count: 1))

        let joinedRefresh = Task {
            await sut.submitRefresh(intent: .serviceBecameRunning)
        }

        let stayedSingleLoad = await staysTrue(timeoutNanoseconds: 100_000_000) {
            await gate.currentCallCount() == 1
        }
        #expect(stayedSingleLoad)
        #expect(sut.store.isLoadingDisplays == true)

        await gate.release(call: 1)

        #expect(await firstRefresh.value.result == .reloadedSnapshot)
        #expect(await joinedRefresh.value.result == .reloadedSnapshot)
        #expect(sut.store.displays?.map(\.displayID) == [808])
        #expect(sut.store.lastRefreshResult == .reloadedSnapshot)
    }

    @Test func deniedPermissionInvalidationCancelsInFlightRefreshBeforeClearingSnapshot() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success])
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [606] }
        )
        sut.store.hasScreenCapturePermission = true

        let refresh = Task { await sut.submitRefresh(intent: .userForcedRefresh) }
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(sut.store.isLoadingDisplays == true)

        let clearSettlement = await sut.clearSnapshotForDeniedPermission(
            loadErrorMessage: "permission denied"
        )
        #expect(clearSettlement.result == .clearedSnapshot)
        #expect(clearSettlement.catalog.hasScreenCapturePermission == false)
        #expect(clearSettlement.catalog.loadedDisplays.isEmpty)
        #expect(sut.store.displays == nil)
        #expect(sut.store.hasScreenCapturePermission == false)
        #expect(sut.store.lastRefreshResult == .clearedSnapshot)
        #expect(sut.store.loadErrorMessage == "permission denied")

        await gate.release(call: 1)
        #expect(await refresh.value == clearSettlement)
        #expect(sut.store.displays == nil)
        #expect(sut.store.hasScreenCapturePermission == false)
        #expect(sut.store.lastRefreshResult == .clearedSnapshot)
        #expect(sut.store.loadErrorMessage == "permission denied")
    }

    @Test func changedDisplayConfigurationReloadsEvenWhenDisplayIDIsUnchanged() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success])
        let displayID = CGDirectDisplayID(909)
        let signatureBox = CatalogServiceSignatureBox([
            makeTestDisplayTopologySignatureEntry(
                displayID: displayID,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        ])
        let refreshedDisplay = SharedMockSCDisplay.make(
            displayID: displayID,
            width: 2560,
            height: 1440
        )
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return [refreshedDisplay]
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [displayID] },
            displayTopologySignatureProvider: { signatureBox.value }
        )
        sut.store.hasScreenCapturePermission = true
        sut.store.displays = [
            SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        ]
        sut.store.lastLoadedActiveDisplayTopologySignature = signatureBox.value

        signatureBox.value = [
            makeTestDisplayTopologySignatureEntry(
                displayID: displayID,
                pixelWidth: 2560,
                pixelHeight: 1440
            )
        ]

        let refresh = Task { await sut.submitRefresh(intent: .topologyChanged) }
        #expect(await waitForLoaderCall(gate, count: 1))
        await gate.release(call: 1)

        #expect(await refresh.value.result == .reloadedSnapshot)
        #expect(sut.store.displays?.map(\.displayID) == [displayID])
        #expect(sut.store.lastLoadedActiveDisplayTopologySignature == signatureBox.value)
    }

    @Test func topologyMismatchBeforeCommitRetriesAndCommitsLatestSnapshot() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success, .success])
        let initialSignature = makeTestDisplayTopologySignature([1001])
        let retriedSignature = makeTestDisplayTopologySignature([1002])
        let signatureBox = CatalogServiceSignatureBox(initialSignature)
        let firstDisplay = SharedMockSCDisplay.make(displayID: 1001, width: 1280, height: 720)
        let retriedDisplay = SharedMockSCDisplay.make(displayID: 1002, width: 1920, height: 1080)
        var loadCallIndex = 0
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                loadCallIndex += 1
                switch await gate.nextOutcome() {
                case .success:
                    return loadCallIndex == 1 ? [firstDisplay] : [retriedDisplay]
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [1002] },
            displayTopologySignatureProvider: { signatureBox.value }
        )
        sut.store.hasScreenCapturePermission = true

        let refresh = Task { await sut.submitRefresh(intent: .topologyChanged) }
        #expect(await waitForLoaderCall(gate, count: 1))

        signatureBox.value = retriedSignature
        await gate.release(call: 1)

        #expect(await waitForLoaderCall(gate, count: 2))
        await gate.release(call: 2)

        #expect(await refresh.value.result == .reloadedSnapshot)
        #expect(await gate.currentCallCount() == 2)
        #expect(sut.store.displays?.map(\.displayID) == [1002])
        #expect(sut.store.lastLoadedActiveDisplayTopologySignature == retriedSignature)
    }

    @Test func topologySignatureJitterRetriesUntilCommitMatchesLatestSample() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success, .success, .success])
        let signatureA = makeTestDisplayTopologySignature([1101])
        let signatureB = makeTestDisplayTopologySignature([1102])
        let finalSignature = makeTestDisplayTopologySignature([1103])
        let signatureBox = CatalogServiceSignatureBox(signatureA)
        let displays = [
            SharedMockSCDisplay.make(displayID: 1101, width: 1280, height: 720),
            SharedMockSCDisplay.make(displayID: 1102, width: 1920, height: 1080),
            SharedMockSCDisplay.make(displayID: 1103, width: 2560, height: 1440)
        ]
        var loadCallIndex = 0
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                loadCallIndex += 1
                switch await gate.nextOutcome() {
                case .success:
                    return [displays[loadCallIndex - 1]]
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [1103] },
            displayTopologySignatureProvider: { signatureBox.value }
        )
        sut.store.hasScreenCapturePermission = true

        let refresh = Task { await sut.submitRefresh(intent: .topologyChanged) }
        #expect(await waitForLoaderCall(gate, count: 1))

        signatureBox.value = signatureB
        await gate.release(call: 1)

        #expect(await waitForLoaderCall(gate, count: 2))
        signatureBox.value = finalSignature
        await gate.release(call: 2)

        #expect(await waitForLoaderCall(gate, count: 3))
        await gate.release(call: 3)

        #expect(await refresh.value.result == .reloadedSnapshot)
        #expect(await gate.currentCallCount() == 3)
        #expect(sut.store.displays?.map(\.displayID) == [1103])
        #expect(sut.store.lastLoadedActiveDisplayTopologySignature == finalSignature)
    }

    @Test func repeatedTopologyMismatchFailsWithoutOverwritingStableSnapshot() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success, .success, .success, .success])
        let stableSignature = makeTestDisplayTopologySignature([1200])
        let signatureBox = CatalogServiceSignatureBox(makeTestDisplayTopologySignature([1201]))
        let stableDisplay = SharedMockSCDisplay.make(displayID: 1200, width: 1440, height: 900)
        var loadCallIndex = 0
        let retrySignatures = [
            makeTestDisplayTopologySignature([1202]),
            makeTestDisplayTopologySignature([1203]),
            makeTestDisplayTopologySignature([1204]),
            makeTestDisplayTopologySignature([1205])
        ]
        let refreshedDisplays = [
            SharedMockSCDisplay.make(displayID: 1201, width: 1280, height: 720),
            SharedMockSCDisplay.make(displayID: 1202, width: 1600, height: 900),
            SharedMockSCDisplay.make(displayID: 1203, width: 1920, height: 1080),
            SharedMockSCDisplay.make(displayID: 1204, width: 2560, height: 1440)
        ]
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                loadCallIndex += 1
                switch await gate.nextOutcome() {
                case .success:
                    return [refreshedDisplays[loadCallIndex - 1]]
                case .failure(let error):
                    throw error
                }
            },
            activeDisplayIDsProvider: { [1205] },
            displayTopologySignatureProvider: { signatureBox.value }
        )
        sut.store.hasScreenCapturePermission = true
        sut.store.displays = [stableDisplay]
        sut.store.lastLoadedActiveDisplayTopologySignature = stableSignature
        sut.store.lastRefreshResult = .reusedSnapshot

        let refresh = Task { await sut.submitRefresh(intent: .topologyChanged) }

        for (index, retrySignature) in retrySignatures.enumerated() {
            #expect(await waitForLoaderCall(gate, count: index + 1))
            signatureBox.value = retrySignature
            await gate.release(call: index + 1)
        }

        #expect(await refresh.value.result == .failed)
        #expect(await gate.currentCallCount() == 4)
        #expect(sut.store.displays?.map(\.displayID) == [1200])
        #expect(sut.store.lastLoadedActiveDisplayTopologySignature == stableSignature)
        #expect(sut.store.lastRefreshResult == .failed)
        #expect(sut.store.lastLoadError == nil)
    }

    private func waitForLoaderCall(
        _ gate: SequencedCatalogServiceLoadGate,
        count: Int
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentCallCount() >= count {
                return true
            }
            await Task.yield()
        }
        return await gate.currentCallCount() >= count
    }

    private func staysTrue(
        timeoutNanoseconds: UInt64,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() == false {
                return false
            }
            await Task.yield()
        }
        return await condition()
    }

    private func eventually(
        timeoutNanoseconds: UInt64,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }
}
