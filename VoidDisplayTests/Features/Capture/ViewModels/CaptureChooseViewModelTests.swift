import Foundation
import CoreGraphics
import Testing
@testable import VoidDisplay

private struct ControlledCaptureLoadFailure: Error, Sendable {}

private actor SequencedCaptureDisplayLoaderGate {
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

struct CaptureChooseViewModelTests {

    @MainActor @Test func withDisplayStartLockRejectsConcurrentStartForSameDisplay() async {
        let sut = CaptureChooseViewModel()
        let displayID = CGDirectDisplayID(301)
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
        let sut = CaptureChooseViewModel()
        let firstDisplayID = CGDirectDisplayID(401)
        let secondDisplayID = CGDirectDisplayID(402)
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

    @MainActor @Test func requestPermissionDeniedClearsDisplayState() {
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: false,
                requestResult: false
            )
        )
        sut.displays = []
        sut.isLoadingDisplays = true

        sut.requestScreenCapturePermission()

        #expect(sut.hasScreenCapturePermission == false)
        #expect(sut.lastRequestPermission == false)
        #expect(sut.lastPreflightPermission == false)
        #expect(sut.displays == nil)
        #expect(sut.isLoadingDisplays == false)
    }

    @MainActor @Test func refreshPermissionGrantedLoadsDisplaysThroughInjectedLoader() async {
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [] }
        )

        sut.refreshPermissionAndMaybeLoad()
        let loaded = await waitUntil {
            sut.isLoadingDisplays == false && sut.displays != nil
        }

        #expect(loaded)
        #expect(sut.hasScreenCapturePermission == true)
        #expect(sut.lastPreflightPermission == true)
        #expect(sut.displays?.isEmpty == true)
    }

    @MainActor @Test func loadDisplaysPersistsErrorDetailsWhenLoaderThrows() async {
        let expected = NSError(domain: "CaptureTests", code: 99)
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { throw expected }
        )

        sut.loadDisplays()
        let finished = await waitUntil {
            sut.isLoadingDisplays == false && sut.lastLoadError != nil
        }

        #expect(finished)
        #expect(sut.loadErrorMessage != nil)
        #expect(sut.lastLoadError?.domain == expected.domain)
        #expect(sut.lastLoadError?.code == expected.code)
        #expect(sut.displays == nil)
    }

    @MainActor @Test func loadDisplaysIgnoresLateResultFromSupersededRequest() async {
        let gate = SequencedCaptureDisplayLoaderGate(
            scriptedOutcomes: [.failure, .success]
        )
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure:
                    throw ControlledCaptureLoadFailure()
                }
            }
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.loadDisplays()
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

    @MainActor @Test func refreshPermissionDeniedCancelsInFlightDisplayLoad() async {
        let gate = SequencedCaptureDisplayLoaderGate(
            scriptedOutcomes: [.success]
        )
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: false,
                requestResult: false
            ),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure:
                    throw ControlledCaptureLoadFailure()
                }
            }
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.refreshPermissionAndMaybeLoad()
        #expect(sut.hasScreenCapturePermission == false)
        #expect(sut.isLoadingDisplays == false)
        #expect(sut.displays == nil)

        await gate.release(call: 1)
        let lateWritePrevented = await waitUntil(timeoutNanoseconds: 500_000_000) {
            sut.isLoadingDisplays == false && sut.displays == nil
        }
        #expect(lateWritePrevented)
    }

    @MainActor
    private func waitForLoaderCall(_ gate: SequencedCaptureDisplayLoaderGate, count: Int) async -> Bool {
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
