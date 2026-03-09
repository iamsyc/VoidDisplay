import Foundation
import Testing
@testable import VoidDisplay

private struct ControlledCatalogLoadFailure: Error, Sendable {}

private actor SequencedCatalogDisplayLoaderGate {
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

private actor AsyncCallFlag {
    private var value = false

    func markCalled() {
        value = true
    }

    func wasCalled() -> Bool {
        value
    }
}

@MainActor
@Suite(.serialized)
struct ScreenCaptureDisplayCatalogLoaderTests {

    @Test func requestPermissionDeniedUpdatesCatalogState() {
        let state = ScreenCaptureDisplayCatalogState()
        let sut = ScreenCaptureDisplayCatalogLoader(
            state: state,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: false, requestResult: false),
            loadShareableDisplays: { [] },
            logOperation: "test",
            logger: AppLog.capture
        )

        let granted = sut.requestPermission()

        #expect(granted == false)
        #expect(state.hasScreenCapturePermission == false)
        #expect(state.lastRequestPermission == false)
        #expect(state.lastPreflightPermission == false)
    }

    @Test func loadDisplaysPersistsErrorDetailsWhenLoaderThrows() async {
        let state = ScreenCaptureDisplayCatalogState()
        let expected = NSError(domain: "CatalogTests", code: 42)
        let sut = ScreenCaptureDisplayCatalogLoader(
            state: state,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { throw expected },
            logOperation: "catalog load",
            logger: AppLog.capture
        )

        sut.loadDisplays()
        let finished = await waitUntil {
            state.isLoadingDisplays == false && state.lastLoadError != nil
        }

        #expect(finished)
        #expect(state.loadErrorMessage != nil)
        #expect(state.lastLoadError?.domain == expected.domain)
        #expect(state.lastLoadError?.code == expected.code)
        #expect(state.displays == nil)
    }

    @Test func loadDisplaysPreserveModeKeepsExistingDisplaysDuringRefreshAndFailure() async {
        let gate = SequencedCatalogDisplayLoaderGate(scriptedOutcomes: [.failure])
        let state = ScreenCaptureDisplayCatalogState()
        state.displays = []

        let sut = ScreenCaptureDisplayCatalogLoader(
            state: state,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure:
                    throw ControlledCatalogLoadFailure()
                }
            },
            logOperation: "catalog load",
            logger: AppLog.capture
        )

        sut.loadDisplays(preserveExistingDisplays: true)
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(state.isLoadingDisplays == true)
        #expect(state.displays != nil)

        await gate.release(call: 1)
        let finished = await waitUntil {
            state.isLoadingDisplays == false && state.lastLoadError != nil
        }
        #expect(finished)
        #expect(state.displays != nil)
    }

    @Test func loadDisplaysDefaultModeClearsExistingDisplaysAtLoadStart() async {
        let gate = SequencedCatalogDisplayLoaderGate(scriptedOutcomes: [.success])
        let state = ScreenCaptureDisplayCatalogState()
        state.displays = []

        let sut = ScreenCaptureDisplayCatalogLoader(
            state: state,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure:
                    throw ControlledCatalogLoadFailure()
                }
            },
            logOperation: "catalog load",
            logger: AppLog.capture
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))
        #expect(state.displays == nil)

        await gate.release(call: 1)
        let finished = await waitUntil {
            state.isLoadingDisplays == false && state.displays != nil
        }
        #expect(finished)
    }

    @Test func loadDisplaysIgnoresLateResultFromSupersededRequest() async {
        let gate = SequencedCatalogDisplayLoaderGate(scriptedOutcomes: [.failure, .success])
        let state = ScreenCaptureDisplayCatalogState()
        let sut = ScreenCaptureDisplayCatalogLoader(
            state: state,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure:
                    throw ControlledCatalogLoadFailure()
                }
            },
            logOperation: "catalog load",
            logger: AppLog.capture
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 2))

        await gate.release(call: 2)
        let secondFinished = await waitUntil {
            state.isLoadingDisplays == false && state.displays != nil && state.lastLoadError == nil
        }
        #expect(secondFinished)

        await gate.release(call: 1)
        let staleResultIgnored = await waitUntil(timeoutNanoseconds: AsyncTestTimeouts.shortStabilityWindow) {
            state.isLoadingDisplays == false && state.displays?.isEmpty == true && state.lastLoadError == nil
        }
        #expect(staleResultIgnored)
    }

    @Test func cancelInFlightDisplayLoadPreventsLateWrite() async {
        let gate = SequencedCatalogDisplayLoaderGate(scriptedOutcomes: [.success])
        let state = ScreenCaptureDisplayCatalogState()
        let sut = ScreenCaptureDisplayCatalogLoader(
            state: state,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                switch await gate.nextOutcome() {
                case .success:
                    return []
                case .failure:
                    throw ControlledCatalogLoadFailure()
                }
            },
            logOperation: "catalog load",
            logger: AppLog.capture
        )

        sut.loadDisplays()
        #expect(await waitForLoaderCall(gate, count: 1))

        sut.cancelInFlightDisplayLoad()
        #expect(state.isLoadingDisplays == false)
        #expect(state.displays == nil)

        await gate.release(call: 1)
        let lateWritePrevented = await waitUntil(timeoutNanoseconds: AsyncTestTimeouts.shortStabilityWindow) {
            state.isLoadingDisplays == false && state.displays == nil
        }
        #expect(lateWritePrevented)
    }

    @Test func uiTestPermissionDeniedScenarioShortCircuitsLoad() async {
        let state = ScreenCaptureDisplayCatalogState()
        let callFlag = AsyncCallFlag()
        let sut = ScreenCaptureDisplayCatalogLoader(
            state: state,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                await callFlag.markCalled()
                return []
            },
            logOperation: "catalog load",
            logger: AppLog.capture,
            runtimeScenarioProbe: .init(
                shouldShortCircuitDisplayLoadAsPermissionDenied: { true }
            )
        )

        sut.loadDisplays()

        #expect(await callFlag.wasCalled() == false)
        #expect(state.hasScreenCapturePermission == false)
        #expect(state.lastPreflightPermission == false)
        #expect(state.displays == nil)
        #expect(state.isLoadingDisplays == false)
    }

    @Test func uiTestDisplayCatalogLoadingScenarioKeepsVisibleLoadingStateBeforeLoaderRuns() async {
        let state = ScreenCaptureDisplayCatalogState()
        let callFlag = AsyncCallFlag()
        let sut = ScreenCaptureDisplayCatalogLoader(
            state: state,
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: {
                await callFlag.markCalled()
                return []
            },
            logOperation: "catalog load",
            logger: AppLog.capture,
            runtimeScenarioProbe: .init(
                shouldShortCircuitDisplayLoadAsPermissionDenied: { false },
                shouldDelayDisplayLoadForUITest: { true }
            )
        )

        sut.loadDisplays()

        #expect(state.isLoadingDisplays == true)
        try? await Task.sleep(nanoseconds: AsyncTestTimeouts.shortStabilityWindow)
        #expect(await callFlag.wasCalled() == false)

        sut.cancelInFlightDisplayLoad()
        #expect(state.isLoadingDisplays == false)
    }

    private func waitForLoaderCall(_ gate: SequencedCatalogDisplayLoaderGate, count: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.defaultAsyncAssertion
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentCallCount() >= count {
                return true
            }
            await Task.yield()
        }
        return await gate.currentCallCount() >= count
    }
}
