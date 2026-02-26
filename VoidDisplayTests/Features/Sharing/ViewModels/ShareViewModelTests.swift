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

@Suite(.serialized)
struct ShareViewModelTests {

    @MainActor @Test func withDisplayStartLockRejectsConcurrentStartForSameDisplay() async {
        let sut = ShareViewModel(dependencies: makeNoopShareDependencies())
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
        let sut = ShareViewModel(dependencies: makeNoopShareDependencies())
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
        let env = makeEnvironment()
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: false,
                requestResult: false
            ),
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )
        sut.catalog.displays = []
        sut.catalog.isLoadingDisplays = true

        sut.requestScreenCapturePermission()

        #expect(sut.catalog.hasScreenCapturePermission == false)
        #expect(sut.catalog.lastRequestPermission == false)
        #expect(sut.catalog.lastPreflightPermission == false)
        #expect(sut.catalog.displays == nil)
        #expect(sut.catalog.isLoadingDisplays == false)
        #expect(sut.catalog.loadErrorMessage != nil)
    }

    @MainActor @Test func loadDisplaysRegistersDisplaysThroughControllers() async {
        let sharing = MockSharingService()
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [] },
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.loadDisplays()
        let finished = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays != nil
        }

        #expect(finished)
        #expect(sut.catalog.displays?.isEmpty == true)
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
            loadShareableDisplays: { throw expected },
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.loadDisplays()
        let finished = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.lastLoadError != nil
        }

        #expect(finished)
        #expect(sut.catalog.loadErrorMessage != nil)
        #expect(sut.catalog.lastLoadError?.domain == expected.domain)
        #expect(sut.catalog.lastLoadError?.code == expected.code)
    }

    @MainActor @Test func startServiceFailureShowsInlinePortError() async {
        let sharing = MockSharingService()
        sharing.startResult = .failed(.portInUse(port: 8081))
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.startService()
        let presented = await waitUntil {
            sut.portInputErrorMessage != nil
        }

        #expect(presented)
        #expect(sharing.startWebServiceCallCount == 1)
        #expect(sut.showOpenPageError == false)
    }

    @MainActor @Test func initUsesPreferredPortAsInputDefault() {
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 9099 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .failed(.timedOut(port: 9099)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _, _, _, _ in },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        #expect(sut.servicePortInput == "9099")
    }

    @MainActor @Test func updateServicePortInputTruncatesToFiveCharacters() {
        let env = makeEnvironment()
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.updateServicePortInput("1234567890")

        #expect(sut.servicePortInput == "12345")
    }

    @MainActor @Test func startServiceWithInvalidPortSkipsStartCallAndShowsValidationError() async {
        let sharing = MockSharingService()
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )
        sut.servicePortInput = "abc"

        sut.startService()
        let presented = await waitUntil {
            sut.portInputErrorMessage != nil
        }

        #expect(presented)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.showOpenPageError == false)
    }

    @MainActor @Test func startServicePassesRequestedPortToSharingLayer() async {
        let sharing = MockSharingService()
        sharing.startResult = .started(WebServiceBinding(requestedPort: 8088, boundPort: 8088))
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )
        sut.servicePortInput = "8088"

        sut.startService()
        let started = await waitUntil {
            sharing.startWebServiceCallCount == 1
        }

        #expect(started)
        #expect(sharing.lastStartRequestedPort == 8088)
    }

    @MainActor @Test func editingPortClearsInlineErrorMessage() async {
        let sharing = MockSharingService()
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.servicePortInput = "bad-port"
        sut.startService()
        _ = await waitUntil { sut.portInputErrorMessage != nil }
        #expect(sut.portInputErrorMessage != nil)

        sut.updateServicePortInput("8081")
        #expect(sut.portInputErrorMessage == nil)
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
            },
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 2))

        await gate.release(call: 2)
        let secondFinished = await waitUntil {
            sut.catalog.isLoadingDisplays == false &&
                sut.catalog.displays != nil &&
                sut.catalog.lastLoadError == nil
        }
        #expect(secondFinished)

        await gate.release(call: 1)
        let staleResultIgnored = await waitUntil(timeoutNanoseconds: AsyncTestTimeouts.shortStabilityWindow) {
            sut.catalog.isLoadingDisplays == false &&
                sut.catalog.displays?.isEmpty == true &&
                sut.catalog.lastLoadError == nil
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
            },
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.stopService()
        #expect(sut.catalog.isLoadingDisplays == false)
        #expect(sut.catalog.displays == nil)

        await gate.release(call: 1)
        let lateWritePrevented = await waitUntil(timeoutNanoseconds: AsyncTestTimeouts.shortStabilityWindow) {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays == nil
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
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            isRunningUnderXCTestOverride: false
        )
    }

    @MainActor
    private func waitForLoaderCall(_ gate: SequencedShareDisplayLoaderGate, count: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.defaultAsyncAssertion
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentCallCount() >= count {
                return true
            }
            await Task.yield()
        }
        return await gate.currentCallCount() >= count
    }

    @MainActor
    private func makeNoopShareDependencies() -> ShareViewModel.Dependencies {
        .init(
            sharingQueries: .init(
                isWebServiceRunning: { false },
                sharePageAddress: { _ in nil },
                preferredWebServicePort: { 8081 }
            ),
            sharingActions: .init(
                startWebService: { _ in .failed(.timedOut(port: 8081)) },
                stopWebService: {},
                registerShareableDisplays: { _, _ in },
                beginSharing: { _, _, _, _ in },
                stopSharing: { _ in }
            ),
            virtualDisplayQueries: .init(
                virtualSerialForManagedDisplay: { _ in nil }
            )
        )
    }
}
