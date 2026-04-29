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

@MainActor
private final class CatalogServiceSignatureBox {
    var value: ScreenCaptureDisplayTopologySignature

    init(_ value: ScreenCaptureDisplayTopologySignature) {
        self.value = value
    }
}

private final class CatalogServiceMockSCDisplayBox: NSObject {
    @objc let displayID: CGDirectDisplayID
    @objc let width: Int
    @objc let height: Int
    @objc let frame: CGRect

    init(displayID: CGDirectDisplayID, width: Int, height: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frame = CGRect(x: 0, y: 0, width: width, height: height)
        super.init()
    }
}

private enum CatalogServiceMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = CatalogServiceMockSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
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

        #expect(result == .reusedSnapshot)
        #expect(sut.store.lastRefreshResult == .reusedSnapshot)
        #expect(await gate.currentCallCount() == 0)
    }

    @Test func permissionDeniedClearsSnapshot() async {
        let sut = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: false, requestResult: false),
            loadShareableDisplays: { [] },
            activeDisplayIDsProvider: { [202] }
        )
        sut.store.displays = []
        sut.store.hasScreenCapturePermission = true
        _ = sut.refreshPermission()

        let result = await sut.submitRefresh(intent: .permissionChanged)

        #expect(result == .clearedSnapshot)
        #expect(sut.store.displays == nil)
        #expect(sut.store.hasScreenCapturePermission == false)
        #expect(sut.store.lastRefreshResult == .clearedSnapshot)
    }

    @Test func supersededRefreshDoesNotOverwriteLatestSnapshot() async {
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
        #expect(await secondRefresh.value == .reloadedSnapshot)
        #expect(sut.store.displays?.isEmpty == true)
        #expect(sut.store.lastLoadError == nil)

        await gate.release(call: 1)
        #expect(await firstRefresh.value == .failed)
        #expect(sut.store.displays?.isEmpty == true)
        #expect(sut.store.lastLoadError == nil)
        #expect(sut.store.lastRefreshResult == .reloadedSnapshot)
    }

    @Test func cancelRefreshOnlyCancelsMatchingOwner() async {
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
            activeDisplayIDsProvider: { [404] }
        )
        let captureOwner = ScreenCaptureCatalogService.RefreshOwner()
        let sharingOwner = ScreenCaptureCatalogService.RefreshOwner()
        sut.store.hasScreenCapturePermission = true

        let refresh = Task {
            await sut.submitRefresh(intent: .userForcedRefresh, owner: captureOwner)
        }
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(sut.store.isLoadingDisplays == true)

        await sut.cancelRefresh(owner: sharingOwner)

        #expect(sut.store.isLoadingDisplays == true)

        await gate.release(call: 1)
        #expect(await refresh.value == .reloadedSnapshot)
        #expect(sut.store.isLoadingDisplays == false)
        #expect(sut.store.lastRefreshResult == .reloadedSnapshot)
    }

    @Test func supersededRefreshDoesNotClearLoadingStateWhileReplacementRuns() async {
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

        #expect(await firstRefresh.value == .failed)
        #expect(sut.store.isLoadingDisplays == true)
        #expect(sut.store.lastLoadError == nil)
        #expect(sut.store.lastRefreshResult == nil)

        await gate.release(call: 2)

        #expect(await secondRefresh.value == .reloadedSnapshot)
        #expect(sut.store.isLoadingDisplays == false)
        #expect(sut.store.lastRefreshResult == .reloadedSnapshot)
    }

    @Test func matchingCachedTopologyJoinsInFlightRefreshInsteadOfReusingStaleSnapshot() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success])
        let staleDisplay = CatalogServiceMockSCDisplay.make(displayID: 707, width: 1280, height: 720)
        let refreshedDisplay = CatalogServiceMockSCDisplay.make(displayID: 808, width: 1920, height: 1080)
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

        #expect(await firstRefresh.value == .reloadedSnapshot)
        #expect(await joinedRefresh.value == .reloadedSnapshot)
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

        await sut.clearSnapshotForDeniedPermission(loadErrorMessage: "permission denied")
        #expect(sut.store.displays == nil)
        #expect(sut.store.hasScreenCapturePermission == false)
        #expect(sut.store.lastRefreshResult == .clearedSnapshot)
        #expect(sut.store.loadErrorMessage == "permission denied")

        await gate.release(call: 1)
        #expect(await refresh.value == .failed)
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
        let refreshedDisplay = CatalogServiceMockSCDisplay.make(
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
            CatalogServiceMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
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

        #expect(await refresh.value == .reloadedSnapshot)
        #expect(sut.store.displays?.map(\.displayID) == [displayID])
        #expect(sut.store.lastLoadedActiveDisplayTopologySignature == signatureBox.value)
    }

    @Test func topologyMismatchBeforeCommitRetriesAndCommitsLatestSnapshot() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success, .success])
        let initialSignature = makeTestDisplayTopologySignature([1001])
        let retriedSignature = makeTestDisplayTopologySignature([1002])
        let signatureBox = CatalogServiceSignatureBox(initialSignature)
        let firstDisplay = CatalogServiceMockSCDisplay.make(displayID: 1001, width: 1280, height: 720)
        let retriedDisplay = CatalogServiceMockSCDisplay.make(displayID: 1002, width: 1920, height: 1080)
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

        #expect(await refresh.value == .reloadedSnapshot)
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
            CatalogServiceMockSCDisplay.make(displayID: 1101, width: 1280, height: 720),
            CatalogServiceMockSCDisplay.make(displayID: 1102, width: 1920, height: 1080),
            CatalogServiceMockSCDisplay.make(displayID: 1103, width: 2560, height: 1440)
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

        #expect(await refresh.value == .reloadedSnapshot)
        #expect(await gate.currentCallCount() == 3)
        #expect(sut.store.displays?.map(\.displayID) == [1103])
        #expect(sut.store.lastLoadedActiveDisplayTopologySignature == finalSignature)
    }

    @Test func repeatedTopologyMismatchFailsWithoutOverwritingStableSnapshot() async {
        let gate = SequencedCatalogServiceLoadGate(scriptedOutcomes: [.success, .success, .success, .success])
        let stableSignature = makeTestDisplayTopologySignature([1200])
        let signatureBox = CatalogServiceSignatureBox(makeTestDisplayTopologySignature([1201]))
        let stableDisplay = CatalogServiceMockSCDisplay.make(displayID: 1200, width: 1440, height: 900)
        var loadCallIndex = 0
        let retrySignatures = [
            makeTestDisplayTopologySignature([1202]),
            makeTestDisplayTopologySignature([1203]),
            makeTestDisplayTopologySignature([1204]),
            makeTestDisplayTopologySignature([1205])
        ]
        let refreshedDisplays = [
            CatalogServiceMockSCDisplay.make(displayID: 1201, width: 1280, height: 720),
            CatalogServiceMockSCDisplay.make(displayID: 1202, width: 1600, height: 900),
            CatalogServiceMockSCDisplay.make(displayID: 1203, width: 1920, height: 1080),
            CatalogServiceMockSCDisplay.make(displayID: 1204, width: 2560, height: 1440)
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

        #expect(await refresh.value == .failed)
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
}
