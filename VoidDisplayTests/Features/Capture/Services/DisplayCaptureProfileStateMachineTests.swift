import Testing
@testable import VoidDisplay

struct DisplayCaptureProfileStateMachineTests {
    @Test func desiredProfileMatchesPreviewAndSharingDemand() {
        #expect(
            DisplayCaptureProfileStateMachine.desiredProfile(
                previewSinkCount: 1,
                sharingActive: false
            ) == .previewOnly
        )
        #expect(
            DisplayCaptureProfileStateMachine.desiredProfile(
                previewSinkCount: 0,
                sharingActive: true
            ) == .shareOnly
        )
        #expect(
            DisplayCaptureProfileStateMachine.desiredProfile(
                previewSinkCount: 2,
                sharingActive: true
            ) == .mixed
        )
        #expect(
            DisplayCaptureProfileStateMachine.desiredProfile(
                previewSinkCount: 0,
                sharingActive: false
            ) == nil
        )
    }

    @Test func firstTransitionAppliesImmediately() {
        let decision = DisplayCaptureProfileStateMachine.decideTransition(
            previewSinkCount: 1,
            sharingActive: true,
            currentProfile: .previewOnly,
            lastProfileSwitchTimeNs: nil,
            nowNs: 10,
            minimumDwellNanoseconds: 5_000_000_000
        )

        switch decision {
        case .applyNow(.mixed):
            break
        default:
            Issue.record("Expected immediate mixed profile transition, got \(String(describing: decision))")
        }
    }

    @Test func dwellWindowSchedulesDelayedTransition() {
        let decision = DisplayCaptureProfileStateMachine.decideTransition(
            previewSinkCount: 0,
            sharingActive: true,
            currentProfile: .previewOnly,
            lastProfileSwitchTimeNs: 1_000,
            nowNs: 2_000,
            minimumDwellNanoseconds: 5_000
        )

        switch decision {
        case .applyAfter(.shareOnly, let delayNanoseconds):
            #expect(delayNanoseconds == 4_000)
        default:
            Issue.record("Expected delayed shareOnly transition, got \(String(describing: decision))")
        }
    }

    @Test func elapsedDwellAppliesImmediately() {
        let decision = DisplayCaptureProfileStateMachine.decideTransition(
            previewSinkCount: 0,
            sharingActive: true,
            currentProfile: .previewOnly,
            lastProfileSwitchTimeNs: 1_000,
            nowNs: 10_000,
            minimumDwellNanoseconds: 5_000
        )

        switch decision {
        case .applyNow(.shareOnly):
            break
        default:
            Issue.record("Expected immediate shareOnly transition, got \(String(describing: decision))")
        }
    }

    @Test func previewFrameRateClampCapsHighRefreshAndPreservesLowerRefresh() {
        #expect(DisplayCaptureSession.clampedPreviewFramesPerSecond(for: 144) == 60)
        #expect(DisplayCaptureSession.clampedPreviewFramesPerSecond(for: 50) == 50)
        #expect(DisplayCaptureSession.clampedPreviewFramesPerSecond(for: 0) == 60)
    }

    @Test func captureProfileFrameRatesMatchCurrentDefaults() {
        #expect(
            DisplayCaptureSession.captureFramesPerSecond(
                for: .previewOnly,
                frameRateTier: .fps60,
                maximumPreviewFramesPerSecond: 60
            ) == 60
        )
        #expect(
            DisplayCaptureSession.captureFramesPerSecond(
                for: .shareOnly,
                frameRateTier: .fps60,
                maximumPreviewFramesPerSecond: 60
            ) == 60
        )
        #expect(
            DisplayCaptureSession.captureFramesPerSecond(
                for: .mixed,
                frameRateTier: .fps45,
                maximumPreviewFramesPerSecond: 60
            ) == 45
        )
    }

    @Test func performanceModesMapToExpectedFrameRateTiers() {
        #expect(
            DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
                for: .previewOnly,
                performanceMode: .automatic
            ) == .fps60
        )
        #expect(
            DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
                for: .shareOnly,
                performanceMode: .automatic
            ) == .fps60
        )
        #expect(
            DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
                for: .mixed,
                performanceMode: .automatic
            ) == .fps45
        )
        #expect(
            DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
                for: .mixed,
                performanceMode: .smooth
            ) == .fps60
        )
        #expect(
            DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
                for: .mixed,
                performanceMode: .powerEfficient
            ) == .fps30
        )
    }

    @Test func automaticMixedModeDropsTo30AfterTwoPressureWindows() {
        var coordinator = DisplayCaptureConfigurationCoordinatorState(
            committedConfiguration: .init(profile: .mixed, frameRateTier: .fps45),
            performanceMode: .automatic
        )
        coordinator.previewSinkCount = 1
        coordinator.sharingActive = true

        let firstDecision = coordinator.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 90,
                droppedFrameCount: 10,
                latestRenderLatencyMilliseconds: 12,
                pendingSlotOccupied: false,
                capturedAt: 1
            ),
            nowNs: 1,
            minimumDwellNanoseconds: 0
        )
        #expect(firstDecision == .noChange)

        let secondDecision = coordinator.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 85,
                droppedFrameCount: 15,
                latestRenderLatencyMilliseconds: 14,
                pendingSlotOccupied: false,
                capturedAt: 2
            ),
            nowNs: 2,
            minimumDwellNanoseconds: 0
        )
        switch secondDecision {
        case .applyNow(let configuration):
            #expect(configuration.profile == .mixed)
            #expect(configuration.frameRateTier == .fps30)
        default:
            Issue.record("Expected automatic mixed mode to drop to 30fps, got \(String(describing: secondDecision))")
        }
    }

    @Test func automaticMixedModeRisesBackTo60AcrossStableWindows() {
        var coordinator = DisplayCaptureConfigurationCoordinatorState(
            committedConfiguration: .init(profile: .mixed, frameRateTier: .fps45),
            performanceMode: .automatic
        )
        coordinator.previewSinkCount = 1
        coordinator.sharingActive = true

        let pressureDecision = coordinator.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 80,
                droppedFrameCount: 20,
                latestRenderLatencyMilliseconds: 10,
                pendingSlotOccupied: false,
                capturedAt: 1
            ),
            nowNs: 1,
            minimumDwellNanoseconds: 0
        )
        #expect(pressureDecision == .noChange)
        let downgradeDecision = coordinator.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 70,
                droppedFrameCount: 30,
                latestRenderLatencyMilliseconds: 10,
                pendingSlotOccupied: false,
                capturedAt: 2
            ),
            nowNs: 2,
            minimumDwellNanoseconds: 0
        )
        guard case .applyNow(let downgradedConfiguration) = downgradeDecision else {
            Issue.record("Expected downgrade to 30fps before stable-window recovery.")
            return
        }
        #expect(downgradedConfiguration.frameRateTier == .fps30)

        let postDowngradeDecision = coordinator.finishAppliedTransition(
            at: 3,
            minimumDwellNanoseconds: 0
        )
        #expect(postDowngradeDecision == .noChange)

        for index in 0..<3 {
            let stableDecision = coordinator.recordPreviewPerformanceSample(
                .init(
                    renderedFrameCount: 100,
                    droppedFrameCount: 0,
                    latestRenderLatencyMilliseconds: 10,
                    pendingSlotOccupied: false,
                    capturedAt: UInt64(10 + index)
                ),
                nowNs: UInt64(10 + index),
                minimumDwellNanoseconds: 0
            )
            #expect(stableDecision == .noChange)
        }

        let fourthStableDecision = coordinator.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 100,
                droppedFrameCount: 0,
                latestRenderLatencyMilliseconds: 10,
                pendingSlotOccupied: false,
                capturedAt: 14
            ),
            nowNs: 14,
            minimumDwellNanoseconds: 0
        )
        switch fourthStableDecision {
        case .applyNow(let configuration):
            #expect(configuration.profile == .mixed)
            #expect(configuration.frameRateTier == .fps45)
        default:
            Issue.record("Expected recovery to 45fps after four stable windows, got \(String(describing: fourthStableDecision))")
        }

        let postRecoveryDecision = coordinator.finishAppliedTransition(
            at: 15,
            minimumDwellNanoseconds: 0
        )
        #expect(postRecoveryDecision == .noChange)

        for index in 0..<3 {
            let stableDecision = coordinator.recordPreviewPerformanceSample(
                .init(
                    renderedFrameCount: 100,
                    droppedFrameCount: 0,
                    latestRenderLatencyMilliseconds: 10,
                    pendingSlotOccupied: false,
                    capturedAt: UInt64(20 + index)
                ),
                nowNs: UInt64(20 + index),
                minimumDwellNanoseconds: 0
            )
            #expect(stableDecision == .noChange)
        }

        let eighthStableDecision = coordinator.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 100,
                droppedFrameCount: 0,
                latestRenderLatencyMilliseconds: 10,
                pendingSlotOccupied: false,
                capturedAt: 24
            ),
            nowNs: 24,
            minimumDwellNanoseconds: 0
        )
        switch eighthStableDecision {
        case .applyNow(let configuration):
            #expect(configuration.profile == .mixed)
            #expect(configuration.frameRateTier == .fps60)
        default:
            Issue.record("Expected recovery to 60fps after another four stable windows, got \(String(describing: eighthStableDecision))")
        }
    }

    @Test func smoothAndPowerEfficientModesIgnoreAutomaticPreviewPressureSamples() {
        var smoothCoordinator = DisplayCaptureConfigurationCoordinatorState(
            committedConfiguration: .init(profile: .mixed, frameRateTier: .fps60),
            performanceMode: .smooth
        )
        smoothCoordinator.previewSinkCount = 1
        smoothCoordinator.sharingActive = true

        let smoothDecision = smoothCoordinator.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 50,
                droppedFrameCount: 50,
                latestRenderLatencyMilliseconds: 60,
                pendingSlotOccupied: true,
                capturedAt: 1
            ),
            nowNs: 1,
            minimumDwellNanoseconds: 0
        )
        #expect(smoothDecision == .noChange)

        var powerCoordinator = DisplayCaptureConfigurationCoordinatorState(
            committedConfiguration: .init(profile: .mixed, frameRateTier: .fps30),
            performanceMode: .powerEfficient
        )
        powerCoordinator.previewSinkCount = 1
        powerCoordinator.sharingActive = true

        let powerDecision = powerCoordinator.recordPreviewPerformanceSample(
            .init(
                renderedFrameCount: 100,
                droppedFrameCount: 0,
                latestRenderLatencyMilliseconds: 5,
                pendingSlotOccupied: false,
                capturedAt: 1
            ),
            nowNs: 1,
            minimumDwellNanoseconds: 0
        )
        #expect(powerDecision == .noChange)
    }

    @Test func committedTransitionUpdatesDwellBeforeReevaluatingPendingDemand() {
        var coordinator = DisplayCaptureProfileCoordinatorState(committedProfile: .previewOnly)

        let initialDecision = coordinator.mutateDemand(
            nowNs: 0,
            minimumDwellNanoseconds: 5_000
        ) { state in
            state.sharingActive = true
        }
        switch initialDecision {
        case .applyNow(.mixed):
            Issue.record("Expected shareOnly transition before preview demand arrives")
        case .applyNow(.shareOnly):
            break
        default:
            Issue.record("Expected immediate shareOnly transition, got \(String(describing: initialDecision))")
        }
        #expect(coordinator.inFlightProfile == .shareOnly)

        let inFlightDecision = coordinator.mutateDemand(
            nowNs: 1_000,
            minimumDwellNanoseconds: 5_000
        ) { state in
            state.previewSinkCount = 1
        }
        #expect(inFlightDecision == .noChange)
        #expect(coordinator.inFlightProfile == .shareOnly)

        let followUpDecision = coordinator.finishAppliedTransition(
            at: 1_000,
            minimumDwellNanoseconds: 5_000
        )
        #expect(coordinator.committedProfile == .shareOnly)
        #expect(coordinator.lastProfileSwitchTimeNs == 1_000)

        switch followUpDecision {
        case .applyAfter(.mixed, let delayNanoseconds):
            #expect(delayNanoseconds == 5_000)
        default:
            Issue.record("Expected delayed mixed transition after committed shareOnly apply, got \(String(describing: followUpDecision))")
        }
    }

    @Test func taskLifetimeInvalidationRejectsOldExecutionGeneration() {
        var lifetime = DisplayCaptureTaskLifetimeState()
        let initialGeneration = lifetime.currentGeneration

        #expect(lifetime.allowsExecution(for: initialGeneration))

        _ = lifetime.invalidateAllTasks()

        #expect(lifetime.allowsExecution(for: initialGeneration) == false)
        #expect(lifetime.allowsExecution(for: lifetime.currentGeneration))
    }
}
