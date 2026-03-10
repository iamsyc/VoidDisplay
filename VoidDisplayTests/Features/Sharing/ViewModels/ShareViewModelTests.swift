import Foundation
import CoreGraphics
import ScreenCaptureKit
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
        #expect(sut.catalog.lastLoadedActiveDisplayTopologySignature != nil)
    }

    @MainActor @Test func refreshPermissionAndMaybeLoadKeepsCachedDisplaysWhenServiceAppearsStopped() {
        let existingDisplay = MockSCDisplay.make(displayID: 9021, width: 1920, height: 1080)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )
        sut.catalog.displays = [existingDisplay]

        sut.refreshPermissionAndMaybeLoad()

        #expect(sut.catalog.hasScreenCapturePermission == true)
        #expect(sut.catalog.displays?.map(\.displayID) == [existingDisplay.displayID])
        #expect(sut.catalog.isLoadingDisplays == false)
    }

    @MainActor @Test func refreshPermissionAndMaybeLoadReloadsWhenTopologyChangesWithCachedDisplays() async {
        let gate = SequencedShareDisplayLoaderGate(scriptedOutcomes: [.success])
        let existingDisplay = MockSCDisplay.make(displayID: 4444, width: 1920, height: 1080)
        let rebuiltDisplay = MockSCDisplay.make(displayID: 5555, width: 2560, height: 1440)
        var registerShareableDisplaysCallCount = 0
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return [rebuiltDisplay]
                case .failure:
                    throw ControlledLoadFailure()
                }
            },
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([5555]) },
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in
                        registerShareableDisplaysCallCount += 1
                    },
                    beginSharing: { _ in },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )
        sut.catalog.displays = [existingDisplay]
        sut.catalog.lastLoadedActiveDisplayTopologySignature = [4444]

        sut.refreshPermissionAndMaybeLoad()
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(sut.catalog.isLoadingDisplays == true)
        #expect(sut.catalog.displays?.map(\.displayID) == [4444])

        await gate.release(call: 1)
        let finished = await waitUntil {
            sut.catalog.isLoadingDisplays == false &&
                sut.catalog.displays?.map(\.displayID) == [5555] &&
                sut.catalog.lastLoadedActiveDisplayTopologySignature == [5555]
        }
        #expect(finished)
        #expect(registerShareableDisplaysCallCount == 1)
    }

    @MainActor @Test func refreshPermissionAndMaybeLoadReloadsWhenCachedDisplaysExistButLoadedTopologySignatureIsMissing() async {
        let gate = SequencedShareDisplayLoaderGate(scriptedOutcomes: [.success])
        let existingDisplay = MockSCDisplay.make(displayID: 4444, width: 1920, height: 1080)
        let rebuiltDisplay = MockSCDisplay.make(displayID: 5555, width: 2560, height: 1440)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return [rebuiltDisplay]
                case .failure:
                    throw ControlledLoadFailure()
                }
            },
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([5555]) },
            dependencies: makeAlwaysRunningShareDependencies()
        )
        sut.catalog.displays = [existingDisplay]
        sut.catalog.lastLoadedActiveDisplayTopologySignature = nil

        sut.refreshPermissionAndMaybeLoad()
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(sut.catalog.isLoadingDisplays == true)
        #expect(sut.catalog.displays?.map(\.displayID) == [4444])

        await gate.release(call: 1)
        let finished = await waitUntil {
            sut.catalog.isLoadingDisplays == false &&
                sut.catalog.displays?.map(\.displayID) == [5555] &&
                sut.catalog.lastLoadedActiveDisplayTopologySignature == [5555]
        }
        #expect(finished)
    }

    @MainActor @Test func refreshPermissionFailureDoesNotCommitLoadedTopologySignatureAndNextRefreshRetries() async {
        let gate = SequencedShareDisplayLoaderGate(scriptedOutcomes: [.failure, .success])
        let existingDisplay = MockSCDisplay.make(displayID: 4444, width: 1920, height: 1080)
        let rebuiltDisplay = MockSCDisplay.make(displayID: 5555, width: 2560, height: 1440)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return [rebuiltDisplay]
                case .failure:
                    throw ControlledLoadFailure()
                }
            },
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([5555]) },
            dependencies: makeAlwaysRunningShareDependencies()
        )
        sut.catalog.displays = [existingDisplay]
        sut.catalog.lastLoadedActiveDisplayTopologySignature = [4444]

        sut.refreshPermissionAndMaybeLoad()
        #expect(await waitForLoaderCall(gate, count: 1))

        await gate.release(call: 1)
        let firstFinished = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.lastLoadError != nil
        }
        #expect(firstFinished)
        #expect(sut.catalog.displays?.map(\.displayID) == [4444])
        #expect(sut.catalog.lastLoadedActiveDisplayTopologySignature == [4444])

        sut.refreshPermissionAndMaybeLoad()
        #expect(await waitForLoaderCall(gate, count: 2))

        await gate.release(call: 2)
        let secondFinished = await waitUntil {
            sut.catalog.isLoadingDisplays == false &&
                sut.catalog.lastLoadError == nil &&
                sut.catalog.displays?.map(\.displayID) == [5555] &&
                sut.catalog.lastLoadedActiveDisplayTopologySignature == [5555]
        }
        #expect(secondFinished)
    }

    @MainActor @Test func syncForCurrentStateClearsDisplaysWhenServiceIsStopped() {
        let existingDisplay = MockSCDisplay.make(displayID: 9022, width: 1920, height: 1080)
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )
        sut.catalog.hasScreenCapturePermission = true
        sut.catalog.displays = [existingDisplay]

        sut.syncForCurrentState()

        #expect(sut.catalog.displays == nil)
        #expect(sut.catalog.isLoadingDisplays == false)
    }

    @MainActor @Test func syncForCurrentStateCancelsLoadWithoutClearingDisplaysWhenServiceStoppedClearIsDisabled() {
        let existingDisplay = MockSCDisplay.make(displayID: 9030, width: 1920, height: 1080)
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )
        sut.catalog.hasScreenCapturePermission = true
        sut.catalog.displays = [existingDisplay]
        sut.catalog.isLoadingDisplays = true

        sut.syncForCurrentState(clearDisplaysWhenServiceStopped: false)

        #expect(sut.catalog.displays?.map(\.displayID) == [existingDisplay.displayID])
        #expect(sut.catalog.isLoadingDisplays == false)
    }

    @MainActor @Test func refreshDisplaysBackgroundSafeStartsLoadWhenIdle() async {
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [] },
            dependencies: makeAlwaysRunningShareDependencies()
        )

        sut.refreshDisplaysBackgroundSafe()
        let finished = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays != nil
        }

        #expect(finished)
        #expect(sut.catalog.displays?.isEmpty == true)
    }

    @MainActor @Test func refreshDisplaysBackgroundSafePreserveModeKeepsExistingDisplaysWhileReloading() async {
        let gate = SequencedShareDisplayLoaderGate(scriptedOutcomes: [.success])
        let existingDisplay = MockSCDisplay.make(displayID: 3333, width: 1920, height: 1080)
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
            dependencies: makeAlwaysRunningShareDependencies()
        )
        sut.catalog.displays = [existingDisplay]

        sut.refreshDisplaysBackgroundSafe()
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(sut.catalog.isLoadingDisplays == true)
        #expect(sut.catalog.displays?.count == 1)

        await gate.release(call: 1)
        let finished = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays != nil
        }
        #expect(finished)
    }

    @MainActor @Test func visibleDisplaysFiltersDisplaysMissingFromCurrentTopology() {
        let displayA = MockSCDisplay.make(displayID: 1234, width: 1920, height: 1080)
        let displayB = MockSCDisplay.make(displayID: 5678, width: 1920, height: 1080)
        let sut = ShareViewModel(
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([1234]) },
            dependencies: makeAlwaysRunningShareDependencies()
        )

        let visible = sut.visibleDisplays(from: [displayA, displayB])
        #expect(visible.map(\.displayID) == [1234])
    }

    @MainActor @Test func refreshDisplaysBackgroundSafeSkipsWhenLoadInFlight() async {
        let gate = SequencedShareDisplayLoaderGate(scriptedOutcomes: [.success])
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
            dependencies: makeAlwaysRunningShareDependencies()
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(sut.catalog.isLoadingDisplays)

        sut.refreshDisplaysBackgroundSafe()
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.shortStabilityWindow
        var observedAdditionalCall = false
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentCallCount() > 1 {
                observedAdditionalCall = true
                break
            }
            await Task.yield()
        }
        #expect(observedAdditionalCall == false)

        await gate.release(call: 1)
        let finished = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays != nil
        }
        #expect(finished)
    }

    @MainActor @Test func refreshDisplaysBackgroundSafeSkipsWhenServiceIsStopped() async {
        let gate = SequencedShareDisplayLoaderGate(scriptedOutcomes: [.success])
        let existingDisplay = MockSCDisplay.make(displayID: 3344, width: 1920, height: 1080)
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
            dependencies: makeNoopShareDependencies()
        )
        sut.catalog.displays = [existingDisplay]
        sut.catalog.lastLoadedActiveDisplayTopologySignature = [existingDisplay.displayID]

        sut.refreshDisplaysBackgroundSafe()

        let stayedIdle = await waitUntil(timeoutNanoseconds: AsyncTestTimeouts.shortStabilityWindow) {
            sut.catalog.isLoadingDisplays == false &&
                sut.catalog.displays?.map(\.displayID) == [existingDisplay.displayID]
        }
        #expect(stayedIdle)
        #expect(await gate.currentCallCount() == 0)
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
        #expect(sut.userFacingAlert == nil)
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
                    beginSharing: { _ in },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        #expect(sut.servicePortInput == "9099")
    }

    @MainActor @Test func servicePortInputTruncatesToFiveCharacters() {
        let env = makeEnvironment()
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.servicePortInput = "1234567890"

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
        #expect(sut.userFacingAlert == nil)
    }

    @MainActor @Test func startServicePassesRequestedPortToSharingLayer() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let sharing = MockSharingService()
        sharing.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )
        sut.servicePortInput = String(requestedPort)

        sut.startService()
        let started = await waitUntil {
            sharing.startWebServiceCallCount == 1
        }

        #expect(started)
        #expect(sharing.lastStartRequestedPort == requestedPort)
    }

    @MainActor @Test func startSharingWithInvalidPortSkipsServiceStartAndSharing() async {
        let display = MockSCDisplay.make(displayID: 7001, width: 1920, height: 1080)
        var startCallCount = 0
        var beginSharingCallCount = 0
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in
                        startCallCount += 1
                        return .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081))
                    },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in
                        beginSharingCallCount += 1
                    },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )
        sut.servicePortInput = "abc"

        await sut.startSharing(display: display)

        #expect(startCallCount == 0)
        #expect(beginSharingCallCount == 0)
        #expect(sut.portInputErrorMessage != nil)
        #expect(sut.userFacingAlert == nil)
    }

    @MainActor @Test func startSharingServiceStartFailureShowsInlineErrorAndSkipsSharing() async {
        let display = MockSCDisplay.make(displayID: 7002, width: 1920, height: 1080)
        var beginSharingCallCount = 0
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .failed(.portInUse(port: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in
                        beginSharingCallCount += 1
                    },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        await sut.startSharing(display: display)

        #expect(beginSharingCallCount == 0)
        #expect(sut.portInputErrorMessage != nil)
        #expect(sut.userFacingAlert == nil)
    }

    @MainActor @Test func startSharingFailureStopsShareAndPresentsAlert() async {
        enum ShareStartFailure: Error {
            case failed
        }

        let display = MockSCDisplay.make(displayID: 7003, width: 1920, height: 1080)
        var stopSharingDisplayIDs: [CGDirectDisplayID] = []
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in
                        throw ShareStartFailure.failed
                    },
                    stopSharing: { displayID in
                        stopSharingDisplayIDs.append(displayID)
                    }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        await sut.startSharing(display: display)

        #expect(stopSharingDisplayIDs == [display.displayID])
        #expect(sut.userFacingAlert?.title == String(localized: "Share Failed"))
        #expect(sut.portInputErrorMessage == nil)
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

        sut.servicePortInput = "8081"
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
                beginSharing: { _ in },
                stopSharing: { _ in }
            ),
            virtualDisplayQueries: .init(
                virtualSerialForManagedDisplay: { _ in nil }
            )
        )
    }

    @MainActor
    private func makeAlwaysRunningShareDependencies() -> ShareViewModel.Dependencies {
        .init(
            sharingQueries: .init(
                isWebServiceRunning: { true },
                sharePageAddress: { _ in nil },
                preferredWebServicePort: { 8081 }
            ),
            sharingActions: .init(
                startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                stopWebService: {},
                registerShareableDisplays: { _, _ in },
                beginSharing: { _ in },
                stopSharing: { _ in }
            ),
            virtualDisplayQueries: .init(
                virtualSerialForManagedDisplay: { _ in nil }
            )
        )
    }
}

private final class MockSCDisplayBox: NSObject {
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

private enum MockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = MockSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}
