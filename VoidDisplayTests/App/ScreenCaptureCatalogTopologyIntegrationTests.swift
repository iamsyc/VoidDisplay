import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private struct IntegrationControlledLoadFailure: Error, Sendable {}

private actor IntegrationSequencedDisplayLoaderGate {
    enum Outcome: Sendable {
        case success
        case failure
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

@MainActor
private final class IntegrationRegisterCounter {
    var value = 0
}

@Suite(.serialized)
@MainActor
struct ScreenCaptureCatalogTopologyIntegrationTests {
    @Test func captureCatalogStateConvergesAcrossViewModelLifecycle() async {
        let staleDisplay = IntegrationMockSCDisplay.make(displayID: 2222, width: 1280, height: 720)
        let refreshedDisplay = IntegrationMockSCDisplay.make(displayID: 3333, width: 2560, height: 1440)
        let sharedCatalogState = ScreenCaptureDisplayCatalogState()
        sharedCatalogState.displays = [staleDisplay]
        sharedCatalogState.lastLoadedActiveDisplayTopologySignature = nil

        let firstGate = IntegrationSequencedDisplayLoaderGate(scriptedOutcomes: [.success])
        let firstVM = CaptureChooseViewModel(
            catalogState: sharedCatalogState,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await firstGate.nextOutcome() {
                case .success:
                    return [refreshedDisplay]
                case .failure:
                    throw IntegrationControlledLoadFailure()
                }
            },
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([3333]) },
            dependencies: makeNoopCaptureDependencies()
        )

        firstVM.refreshPermissionAndMaybeLoad()
        #expect(await waitForLoaderCall(firstGate, count: 1))
        await firstGate.release(call: 1)

        let firstRefreshFinished = await waitUntil {
            sharedCatalogState.isLoadingDisplays == false &&
                sharedCatalogState.displays?.map(\.displayID) == [3333] &&
                sharedCatalogState.lastLoadedActiveDisplayTopologySignature == [3333]
        }
        #expect(firstRefreshFinished)

        let secondGate = IntegrationSequencedDisplayLoaderGate(scriptedOutcomes: [.success])
        let secondVM = CaptureChooseViewModel(
            catalogState: sharedCatalogState,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await secondGate.nextOutcome() {
                case .success:
                    return [refreshedDisplay]
                case .failure:
                    throw IntegrationControlledLoadFailure()
                }
            },
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([3333]) },
            dependencies: makeNoopCaptureDependencies()
        )

        secondVM.refreshPermissionAndMaybeLoad()
        let secondCheckDeadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.shortStabilityWindow
        var observedUnexpectedLoad = false
        while DispatchTime.now().uptimeNanoseconds < secondCheckDeadline {
            if await secondGate.currentCallCount() > 0 {
                observedUnexpectedLoad = true
                break
            }
            await Task.yield()
        }
        #expect(observedUnexpectedLoad == false)
    }

    @Test func shareCatalogStateConvergesAcrossViewModelLifecycle() async {
        let staleDisplay = IntegrationMockSCDisplay.make(displayID: 4444, width: 1920, height: 1080)
        let refreshedDisplay = IntegrationMockSCDisplay.make(displayID: 5555, width: 2560, height: 1440)
        let sharedCatalogState = ScreenCaptureDisplayCatalogState()
        sharedCatalogState.displays = [staleDisplay]
        sharedCatalogState.lastLoadedActiveDisplayTopologySignature = [4444]
        let registerCounter = IntegrationRegisterCounter()

        let firstGate = IntegrationSequencedDisplayLoaderGate(scriptedOutcomes: [.success])
        let firstVM = ShareViewModel(
            catalogState: sharedCatalogState,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await firstGate.nextOutcome() {
                case .success:
                    return [refreshedDisplay]
                case .failure:
                    throw IntegrationControlledLoadFailure()
                }
            },
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([5555]) },
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in
                        registerCounter.value += 1
                    },
                    beginSharing: { _ in .started(()) },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        firstVM.refreshPermissionAndMaybeLoad()
        #expect(await waitForLoaderCall(firstGate, count: 1))
        await firstGate.release(call: 1)

        let firstRefreshFinished = await waitUntil {
            sharedCatalogState.isLoadingDisplays == false &&
                sharedCatalogState.displays?.map(\.displayID) == [5555] &&
                sharedCatalogState.lastLoadedActiveDisplayTopologySignature == [5555]
        }
        #expect(firstRefreshFinished)
        #expect(registerCounter.value >= 1)

        let secondGate = IntegrationSequencedDisplayLoaderGate(scriptedOutcomes: [.success])
        let secondVM = ShareViewModel(
            catalogState: sharedCatalogState,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await secondGate.nextOutcome() {
                case .success:
                    return [refreshedDisplay]
                case .failure:
                    throw IntegrationControlledLoadFailure()
                }
            },
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([5555]) },
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in
                        registerCounter.value += 1
                    },
                    beginSharing: { _ in .started(()) },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        secondVM.refreshPermissionAndMaybeLoad()
        let secondCheckDeadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.shortStabilityWindow
        var observedUnexpectedLoad = false
        while DispatchTime.now().uptimeNanoseconds < secondCheckDeadline {
            if await secondGate.currentCallCount() > 0 {
                observedUnexpectedLoad = true
                break
            }
            await Task.yield()
        }
        #expect(observedUnexpectedLoad == false)
        #expect(registerCounter.value >= 2)
    }

    private func waitForLoaderCall(_ gate: IntegrationSequencedDisplayLoaderGate, count: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.defaultAsyncAssertion
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentCallCount() >= count {
                return true
            }
            await Task.yield()
        }
        return await gate.currentCallCount() >= count
    }

    private func makeNoopCaptureDependencies() -> CaptureChooseViewModel.Dependencies {
        .init(
            captureActions: .init(
                monitoringSessionForDisplayID: { _ in nil },
                isStartingDisplayID: { _ in false },
                startMonitoring: { _, _ in .started(UUID()) }
            ),
            virtualDisplayQueries: .init(
                isManagedVirtualDisplay: { _ in false }
            )
        )
    }
}

private final class IntegrationMockSCDisplayBox: NSObject {
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

private enum IntegrationMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = IntegrationMockSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}
