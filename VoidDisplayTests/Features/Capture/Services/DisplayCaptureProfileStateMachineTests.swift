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
