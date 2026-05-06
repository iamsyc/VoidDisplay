@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import Foundation
import Synchronization
import Testing

private func makeDriverDemand(
    attachedPreviewSinkCount: Int = 0,
    shareTokenCount: Int = 0,
    previewShowsCursor: Bool = false,
    shareCursorOverrideCount: Int = 0,
    performanceMode: CapturePerformanceMode = .automatic
) -> DisplayCaptureDemandSnapshot {
    DisplayCaptureDemandSnapshot(
        attachedPreviewSinkCount: attachedPreviewSinkCount,
        shareTokenCount: shareTokenCount,
        previewShowsCursor: previewShowsCursor,
        shareCursorOverrideCount: shareCursorOverrideCount,
        performanceMode: performanceMode
    )
}

private final class DemandDriverTimeSource: @unchecked Sendable {
    private let value: Mutex<UInt64>

    nonisolated init(_ initialValue: UInt64) {
        self.value = Mutex(initialValue)
    }

    nonisolated func set(_ newValue: UInt64) {
        value.withLock { $0 = newValue }
    }

    nonisolated func now() -> UInt64 {
        value.withLock { $0 }
    }
}

private final class DemandDriverRecorder: @unchecked Sendable {
    private struct State {
        var immediateDemands: [DisplayCaptureDemandSnapshot] = []
        var configurations: [DisplayCaptureConfiguration] = []
        var appliedConfigurations: [DisplayCaptureConfiguration] = []
        var failureCount = 0
    }

    private let state = Mutex(State())

    nonisolated func recordImmediateDemand(_ demand: DisplayCaptureDemandSnapshot) {
        state.withLock { $0.immediateDemands.append(demand) }
    }

    nonisolated func recordConfiguration(_ configuration: DisplayCaptureConfiguration) {
        state.withLock { $0.configurations.append(configuration) }
    }

    nonisolated func recordAppliedConfiguration(_ configuration: DisplayCaptureConfiguration) {
        state.withLock { $0.appliedConfigurations.append(configuration) }
    }

    nonisolated func recordFailure() {
        state.withLock { $0.failureCount += 1 }
    }

    nonisolated var immediateDemands: [DisplayCaptureDemandSnapshot] {
        state.withLock { $0.immediateDemands }
    }

    nonisolated var configurations: [DisplayCaptureConfiguration] {
        state.withLock { $0.configurations }
    }

    nonisolated var appliedConfigurations: [DisplayCaptureConfiguration] {
        state.withLock { $0.appliedConfigurations }
    }

    nonisolated var failureCount: Int {
        state.withLock { $0.failureCount }
    }
}

struct DisplayCaptureDemandDriverTests {
    @Test func setDemandAppliesImmediateDemandAndMixedConfiguration() async throws {
        let timeSource = DemandDriverTimeSource(1)
        let recorder = DemandDriverRecorder()
        let driver = DisplayCaptureDemandDriver(
            initialConfiguration: .init(profile: .previewOnly, frameRateTier: .fps60),
            initialDemand: makeDriverDemand(attachedPreviewSinkCount: 1),
            minimumDwellNanoseconds: 0,
            currentTimeNanoseconds: timeSource.now,
            applyImmediateDemand: { demand in
                recorder.recordImmediateDemand(demand)
                return true
            },
            applyConfiguration: { configuration in
                recorder.recordConfiguration(configuration)
                return true
            },
            onConfigurationApplied: { configuration in
                recorder.recordAppliedConfiguration(configuration)
            },
            onConfigurationFailure: { _ in
                recorder.recordFailure()
            }
        )

        let demand = makeDriverDemand(
            attachedPreviewSinkCount: 1,
            shareTokenCount: 1,
            previewShowsCursor: true
        )
        try await driver.setDemand(demand)

        #expect(recorder.immediateDemands.last == demand)
        #expect(
            await waitUntil {
                recorder.configurations == [.init(profile: .mixed, frameRateTier: .fps60)] &&
                    recorder.appliedConfigurations == [.init(profile: .mixed, frameRateTier: .fps60)]
            }
        )
        #expect(recorder.failureCount == 0)
    }

    @Test func delayedConfigurationAppliesAfterDwellWindow() async throws {
        let timeSource = DemandDriverTimeSource(1)
        let recorder = DemandDriverRecorder()
        let driver = DisplayCaptureDemandDriver(
            initialConfiguration: .init(profile: .previewOnly, frameRateTier: .fps60),
            initialDemand: makeDriverDemand(attachedPreviewSinkCount: 1),
            minimumDwellNanoseconds: 50_000_000,
            currentTimeNanoseconds: timeSource.now,
            applyImmediateDemand: { demand in
                recorder.recordImmediateDemand(demand)
                return true
            },
            applyConfiguration: { configuration in
                recorder.recordConfiguration(configuration)
                return true
            },
            onConfigurationApplied: { configuration in
                recorder.recordAppliedConfiguration(configuration)
            }
        )

        try await driver.setDemand(makeDriverDemand(shareTokenCount: 1))
        #expect(
            await waitUntil {
                recorder.configurations == [.init(profile: .shareOnly, frameRateTier: .fps60)]
            }
        )

        timeSource.set(2)
        try await driver.setDemand(
            makeDriverDemand(attachedPreviewSinkCount: 1, shareTokenCount: 1)
        )

        #expect(
            await staysTrue(timeoutNanoseconds: 10_000_000) {
                recorder.configurations.count == 1
            }
        )

        timeSource.set(100_000_000)
        #expect(
            await waitUntil {
                recorder.configurations == [
                    .init(profile: .shareOnly, frameRateTier: .fps60),
                    .init(profile: .mixed, frameRateTier: .fps60)
                ]
            }
        )
    }

    @Test func newerDemandCancelsObsoleteDelayedTransition() async throws {
        let timeSource = DemandDriverTimeSource(1)
        let recorder = DemandDriverRecorder()
        let driver = DisplayCaptureDemandDriver(
            initialConfiguration: .init(profile: .previewOnly, frameRateTier: .fps60),
            initialDemand: makeDriverDemand(attachedPreviewSinkCount: 1),
            minimumDwellNanoseconds: 50_000_000,
            currentTimeNanoseconds: timeSource.now,
            applyImmediateDemand: { demand in
                recorder.recordImmediateDemand(demand)
                return true
            },
            applyConfiguration: { configuration in
                recorder.recordConfiguration(configuration)
                return true
            }
        )

        try await driver.setDemand(makeDriverDemand(shareTokenCount: 1))
        #expect(
            await waitUntil {
                recorder.configurations == [.init(profile: .shareOnly, frameRateTier: .fps60)]
            }
        )

        timeSource.set(2)
        try await driver.setDemand(
            makeDriverDemand(attachedPreviewSinkCount: 1, shareTokenCount: 1)
        )
        timeSource.set(3)
        try await driver.setDemand(makeDriverDemand(shareTokenCount: 1))
        timeSource.set(100_000_000)

        #expect(
            await staysTrue(timeoutNanoseconds: 80_000_000) {
                recorder.configurations == [.init(profile: .shareOnly, frameRateTier: .fps60)]
            }
        )
    }

    @Test func failedConfigurationApplyReportsFailureAndAllowsRetry() async throws {
        let timeSource = DemandDriverTimeSource(1)
        let recorder = DemandDriverRecorder()
        let shouldFailNext = Mutex(true)
        struct TestFailure: Error {}

        let driver = DisplayCaptureDemandDriver(
            initialConfiguration: .init(profile: .previewOnly, frameRateTier: .fps60),
            initialDemand: makeDriverDemand(attachedPreviewSinkCount: 1),
            minimumDwellNanoseconds: 0,
            currentTimeNanoseconds: timeSource.now,
            applyImmediateDemand: { demand in
                recorder.recordImmediateDemand(demand)
                return demand.showsCursor
            },
            applyConfiguration: { configuration in
                let shouldFail = shouldFailNext.withLock { state -> Bool in
                    let current = state
                    state = false
                    return current
                }
                if shouldFail {
                    throw TestFailure()
                }
                recorder.recordConfiguration(configuration)
                return true
            },
            onConfigurationApplied: { configuration in
                recorder.recordAppliedConfiguration(configuration)
            },
            onConfigurationFailure: { _ in
                recorder.recordFailure()
            }
        )

        try await driver.setDemand(makeDriverDemand(shareTokenCount: 1))
        #expect(await waitUntil { recorder.failureCount == 1 })
        #expect(recorder.configurations.isEmpty)

        timeSource.set(2)
        try await driver.setDemand(makeDriverDemand(shareTokenCount: 1))
        #expect(
            await waitUntil {
                recorder.configurations == [.init(profile: .shareOnly, frameRateTier: .fps60)] &&
                    recorder.appliedConfigurations == [.init(profile: .shareOnly, frameRateTier: .fps60)]
            }
        )
    }

    @Test func previewPressureSamplesKeepAutomaticMixedAt60() async {
        let timeSource = DemandDriverTimeSource(1)
        let recorder = DemandDriverRecorder()
        let driver = DisplayCaptureDemandDriver(
            initialConfiguration: .init(profile: .mixed, frameRateTier: .fps60),
            initialDemand: makeDriverDemand(
                attachedPreviewSinkCount: 1,
                shareTokenCount: 1
            ),
            minimumDwellNanoseconds: 0,
            currentTimeNanoseconds: timeSource.now,
            applyImmediateDemand: { demand in
                recorder.recordImmediateDemand(demand)
                return demand.showsCursor
            },
            applyConfiguration: { configuration in
                recorder.recordConfiguration(configuration)
                return true
            },
            onConfigurationApplied: { configuration in
                recorder.recordAppliedConfiguration(configuration)
            }
        )

        driver.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 90,
                droppedFrameCount: 10,
                latestRenderLatencyMilliseconds: 12,
                pendingSlotOccupied: false,
                capturedAt: 1
            )
        )
        timeSource.set(2)
        driver.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 80,
                droppedFrameCount: 20,
                latestRenderLatencyMilliseconds: 15,
                pendingSlotOccupied: false,
                capturedAt: 2
            )
        )

        #expect(
            await staysTrue(timeoutNanoseconds: 10_000_000) {
                recorder.configurations.isEmpty
            }
        )
    }

    @Test func cursorDemandAppliesImmediatelyWithoutWaitingForProfileDwell() async throws {
        let timeSource = DemandDriverTimeSource(1)
        let recorder = DemandDriverRecorder()
        let driver = DisplayCaptureDemandDriver(
            initialConfiguration: .init(profile: .shareOnly, frameRateTier: .fps60),
            initialDemand: makeDriverDemand(shareTokenCount: 1),
            minimumDwellNanoseconds: 50_000_000,
            currentTimeNanoseconds: timeSource.now,
            applyImmediateDemand: { demand in
                recorder.recordImmediateDemand(demand)
                return true
            },
            applyConfiguration: { configuration in
                recorder.recordConfiguration(configuration)
                return true
            }
        )

        let demand = makeDriverDemand(
            shareTokenCount: 1,
            shareCursorOverrideCount: 1
        )
        try await driver.setDemand(demand)

        #expect(recorder.immediateDemands.last == demand)
        #expect(
            await staysTrue(timeoutNanoseconds: 10_000_000) {
                recorder.configurations.isEmpty
            }
        )
    }
}
