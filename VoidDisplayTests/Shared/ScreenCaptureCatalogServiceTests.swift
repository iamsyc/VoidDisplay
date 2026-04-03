import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

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
        sut.store.lastLoadedActiveDisplayTopologySignature = [101]

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
        sut.store.lastLoadedActiveDisplayTopologySignature = [707]

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
