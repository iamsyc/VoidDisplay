import Foundation
import CoreGraphics
import ScreenCaptureKit
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

@Suite(.serialized)
struct CaptureChooseViewModelTests {
    @MainActor @Test func displayHelpersUseDisplayMetadataAndVirtualQuery() {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    monitoringSessionForDisplayID: { _ in nil },
                    addMonitoringSession: { _ in }
                ),
                virtualDisplayQueries: .init(
                    isManagedVirtualDisplay: { $0 == 1234 }
                )
            )
        )
        let display = MockSCDisplay.make(displayID: 1234, width: 1920, height: 1080)

        #expect(sut.isVirtualDisplay(display))
        #expect(sut.resolutionText(for: display) == "1920 × 1080")
        #expect(sut.displayName(for: display) == String(localized: "Monitor"))
    }

    @MainActor @Test func dependenciesLiveDelegatesToControllers() {
        let captureService = MockCaptureMonitoringService()
        let captureController = CaptureController(captureMonitoringService: captureService)
        let virtualDisplayController = VirtualDisplayController(
            virtualDisplayService: MockVirtualDisplayService(),
            appliedBadgeDisplayDurationNanoseconds: 1,
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        let dependencies = CaptureChooseViewModel.Dependencies.live(
            capture: captureController,
            virtualDisplay: virtualDisplayController
        )

        #expect(dependencies.captureActions.monitoringSessionForDisplayID(777) == nil)
        #expect(dependencies.virtualDisplayQueries.isManagedVirtualDisplay(777) == false)
    }

    @MainActor @Test func withDisplayStartLockRejectsConcurrentStartForSameDisplay() async {
        let sut = CaptureChooseViewModel(dependencies: makeNoopCaptureDependencies())
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
        let sut = CaptureChooseViewModel(dependencies: makeNoopCaptureDependencies())
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
            ),
            dependencies: makeNoopCaptureDependencies()
        )
        sut.catalog.displays = []
        sut.catalog.isLoadingDisplays = true

        sut.requestScreenCapturePermission()

        #expect(sut.catalog.hasScreenCapturePermission == false)
        #expect(sut.catalog.lastRequestPermission == false)
        #expect(sut.catalog.lastPreflightPermission == false)
        #expect(sut.catalog.displays == nil)
        #expect(sut.catalog.isLoadingDisplays == false)
    }

    @MainActor @Test func requestPermissionGrantedLoadsDisplays() async {
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [] },
            dependencies: makeNoopCaptureDependencies()
        )

        sut.requestScreenCapturePermission()
        let loaded = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays != nil
        }

        #expect(loaded)
        #expect(sut.catalog.hasScreenCapturePermission == true)
        #expect(sut.catalog.lastRequestPermission == true)
        #expect(sut.catalog.displays?.isEmpty == true)
    }

    @MainActor @Test func refreshPermissionGrantedLoadsDisplaysThroughInjectedLoader() async {
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [] },
            dependencies: makeNoopCaptureDependencies()
        )

        sut.refreshPermissionAndMaybeLoad()
        let loaded = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays != nil
        }

        #expect(loaded)
        #expect(sut.catalog.hasScreenCapturePermission == true)
        #expect(sut.catalog.lastPreflightPermission == true)
        #expect(sut.catalog.displays?.isEmpty == true)
    }

    @MainActor @Test func loadDisplaysPersistsErrorDetailsWhenLoaderThrows() async {
        let expected = NSError(domain: "CaptureTests", code: 99)
        let sut = CaptureChooseViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { throw expected },
            dependencies: makeNoopCaptureDependencies()
        )

        sut.loadDisplays()
        let finished = await waitUntil {
            sut.catalog.isLoadingDisplays == false && sut.catalog.lastLoadError != nil
        }

        #expect(finished)
        #expect(sut.catalog.loadErrorMessage != nil)
        #expect(sut.catalog.lastLoadError?.domain == expected.domain)
        #expect(sut.catalog.lastLoadError?.code == expected.code)
        #expect(sut.catalog.displays == nil)
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
            },
            dependencies: makeNoopCaptureDependencies()
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
            },
            dependencies: makeNoopCaptureDependencies()
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.refreshPermissionAndMaybeLoad()
        #expect(sut.catalog.hasScreenCapturePermission == false)
        #expect(sut.catalog.isLoadingDisplays == false)
        #expect(sut.catalog.displays == nil)

        await gate.release(call: 1)
        let lateWritePrevented = await waitUntil(timeoutNanoseconds: AsyncTestTimeouts.shortStabilityWindow) {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays == nil
        }
        #expect(lateWritePrevented)
    }

    @MainActor @Test func cancelInFlightDisplayLoadPreventsLateWrite() async {
        let gate = SequencedCaptureDisplayLoaderGate(scriptedOutcomes: [.success])
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
            },
            dependencies: makeNoopCaptureDependencies()
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))
        sut.cancelInFlightDisplayLoad()
        #expect(sut.catalog.isLoadingDisplays == false)

        await gate.release(call: 1)
        let lateWritePrevented = await waitUntil(timeoutNanoseconds: AsyncTestTimeouts.shortStabilityWindow) {
            sut.catalog.isLoadingDisplays == false && sut.catalog.displays == nil
        }
        #expect(lateWritePrevented)
    }

    @MainActor @Test func openScreenCapturePrivacySettingsProvidesURL() {
        let sut = CaptureChooseViewModel(dependencies: makeNoopCaptureDependencies())
        var openedURL: URL?

        sut.openScreenCapturePrivacySettings { url in
            openedURL = url
        }

        #expect(openedURL != nil)
        #expect(openedURL?.scheme?.isEmpty == false)
    }

    @MainActor
    private func waitForLoaderCall(_ gate: SequencedCaptureDisplayLoaderGate, count: Int) async -> Bool {
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
    private func makeNoopCaptureDependencies() -> CaptureChooseViewModel.Dependencies {
        .init(
            captureActions: .init(
                monitoringSessionForDisplayID: { _ in nil },
                addMonitoringSession: { _ in }
            ),
            virtualDisplayQueries: .init(
                isManagedVirtualDisplay: { _ in false }
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
