import Foundation
import CoreGraphics
import Testing
@testable import VoidDisplay

private struct ControlledLoadFailure: Error, Sendable {}

private actor SequencedShareDisplayLoaderGate {
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

struct ShareViewModelTests {

    @MainActor @Test func withDisplayStartLockRejectsConcurrentStartForSameDisplay() async {
        let sut = ShareViewModel()
        let displayID = CGDirectDisplayID(101)
        var enteredCount = 0
        var firstDidEnter = false
        var allowFirstToFinish = false

        let firstTask = Task { @MainActor in
            await sut.withDisplayStartLock(displayID: displayID) {
                enteredCount += 1
                firstDidEnter = true
                while !allowFirstToFinish {
                    await Task.yield()
                }
            }
        }

        while !firstDidEnter {
            await Task.yield()
        }

        let secondStarted = await sut.withDisplayStartLock(displayID: displayID) {
            enteredCount += 1
        }

        allowFirstToFinish = true
        let firstStarted = await firstTask.value

        #expect(firstStarted)
        #expect(secondStarted == false)
        #expect(enteredCount == 1)
        #expect(sut.startingDisplayIDs.isEmpty)
    }

    @MainActor @Test func withDisplayStartLockAllowsConcurrentStartForDifferentDisplays() async {
        let sut = ShareViewModel()
        let firstDisplayID = CGDirectDisplayID(201)
        let secondDisplayID = CGDirectDisplayID(202)
        var enteredDisplayIDs: Set<CGDirectDisplayID> = []
        var firstDidEnter = false
        var allowFirstToFinish = false

        let firstTask = Task { @MainActor in
            await sut.withDisplayStartLock(displayID: firstDisplayID) {
                enteredDisplayIDs.insert(firstDisplayID)
                firstDidEnter = true
                while !allowFirstToFinish {
                    await Task.yield()
                }
            }
        }

        while !firstDidEnter {
            await Task.yield()
        }

        let secondStarted = await sut.withDisplayStartLock(displayID: secondDisplayID) {
            enteredDisplayIDs.insert(secondDisplayID)
        }

        allowFirstToFinish = true
        let firstStarted = await firstTask.value

        #expect(firstStarted)
        #expect(secondStarted)
        #expect(enteredDisplayIDs == [firstDisplayID, secondDisplayID])
        #expect(sut.startingDisplayIDs.isEmpty)
    }

    @MainActor @Test func requestPermissionDeniedClearsDisplaysAndSetsErrorMessage() {
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: false,
                requestResult: false
            )
        )
        let env = makeEnvironment()
        sut.displays = []
        sut.isLoadingDisplays = true

        sut.requestScreenCapturePermission(sharing: env.sharing, virtualDisplay: env.virtualDisplay)

        #expect(sut.hasScreenCapturePermission == false)
        #expect(sut.lastRequestPermission == false)
        #expect(sut.lastPreflightPermission == false)
        #expect(sut.displays == nil)
        #expect(sut.isLoadingDisplays == false)
        #expect(sut.loadErrorMessage != nil)
    }

    @MainActor @Test func loadDisplaysRegistersDisplaysThroughControllers() async {
        let sharing = MockSharingService()
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [] }
        )

        sut.loadDisplays(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        let finished = await waitUntil {
            sut.isLoadingDisplays == false && sut.displays != nil
        }

        #expect(finished)
        #expect(sut.displays?.isEmpty == true)
        #expect(sharing.registerShareableDisplaysCallCount == 1)
    }

    @MainActor @Test func loadDisplaysRecordsDetailedErrorWhenLoaderFails() async {
        let env = makeEnvironment()
        let expected = NSError(domain: "ShareTests", code: 77)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { throw expected }
        )

        sut.loadDisplays(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        let finished = await waitUntil {
            sut.isLoadingDisplays == false && sut.lastLoadError != nil
        }

        #expect(finished)
        #expect(sut.loadErrorMessage != nil)
        #expect(sut.lastLoadError?.domain == expected.domain)
        #expect(sut.lastLoadError?.code == expected.code)
    }

    @MainActor @Test func startServiceFailurePresentsUserFacingError() async {
        let sharing = MockSharingService()
        sharing.startResult = false
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            )
        )

        sut.startService(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        let presented = await waitUntil {
            sut.showOpenPageError
        }

        #expect(presented)
        #expect(sharing.startWebServiceCallCount == 1)
        #expect(sut.openPageErrorMessage.isEmpty == false)
    }

    @MainActor @Test func loadDisplaysIgnoresLateResultFromSupersededRequest() async {
        let gate = SequencedShareDisplayLoaderGate(
            scriptedOutcomes: [.failure, .success]
        )
        let env = makeEnvironment()
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure:
                    throw ControlledLoadFailure()
                }
            }
        )

        sut.loadDisplays(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.loadDisplays(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        #expect(await waitForLoaderCall(gate, count: 2))

        await gate.release(call: 2)
        let secondFinished = await waitUntil {
            sut.isLoadingDisplays == false &&
                sut.displays != nil &&
                sut.lastLoadError == nil
        }
        #expect(secondFinished)

        await gate.release(call: 1)
        let staleResultIgnored = await waitUntil(timeoutNanoseconds: 500_000_000) {
            sut.isLoadingDisplays == false &&
                sut.displays?.isEmpty == true &&
                sut.lastLoadError == nil
        }
        #expect(staleResultIgnored)
    }

    @MainActor @Test func stopServiceCancelsInFlightDisplayLoadAndPreventsLateWrite() async {
        let gate = SequencedShareDisplayLoaderGate(
            scriptedOutcomes: [.success]
        )
        let sharing = MockSharingService()
        sharing.isWebServiceRunning = true
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure:
                    throw ControlledLoadFailure()
                }
            }
        )

        sut.loadDisplays(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.stopService(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        #expect(sut.isLoadingDisplays == false)
        #expect(sut.displays == nil)

        await gate.release(call: 1)
        let lateWritePrevented = await waitUntil(timeoutNanoseconds: 500_000_000) {
            sut.isLoadingDisplays == false && sut.displays == nil
        }
        #expect(lateWritePrevented)
    }

    @MainActor
    private func makeEnvironment() -> AppEnvironment {
        makeEnvironment(sharing: MockSharingService())
    }

    @MainActor
    private func makeEnvironment(sharing: MockSharingService) -> AppEnvironment {
        AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: sharing,
            virtualDisplayService: MockVirtualDisplayService(),
            isRunningUnderXCTestOverride: false
        )
    }

    @MainActor
    private func waitForLoaderCall(_ gate: SequencedShareDisplayLoaderGate, count: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentCallCount() >= count {
                return true
            }
            await Task.yield()
        }
        return await gate.currentCallCount() >= count
    }
}
