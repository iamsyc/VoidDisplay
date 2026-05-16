@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreVideo
import Testing

private func makeTestStreamConfigurationState(
    width: Int = 1920,
    height: Int = 1080,
    profile: DisplayCaptureProfile = .mixed,
    frameRateTier: DisplayCaptureFrameRateTier = .fps45,
    previewShowsCursor: Bool = false,
    shareCursorOverrideCount: Int = 0
) -> DisplayCaptureStreamConfigurationState {
    DisplayCaptureStreamConfigurationState(
        width: width,
        height: height,
        maximumPreviewFramesPerSecond: 60,
        queueDepth: 2,
        capturesAudio: false,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        profile: profile,
        frameRateTier: frameRateTier,
        previewShowsCursor: previewShowsCursor,
        shareCursorOverrideCount: shareCursorOverrideCount
    )
}

private func makeDemand(
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

private actor StreamConfigurationApplyGate {
    private var isOpen = false
    private var enteredCount = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForFirstEntry() async {
        guard enteredCount == 0 else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func enter() async {
        enteredCount += 1
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in pendingEntryWaiters {
            waiter.resume()
        }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingOpenWaiters = openWaiters
        openWaiters.removeAll()
        for waiter in pendingOpenWaiters {
            waiter.resume()
        }
    }
}

private actor StreamConfigurationRecorder {
    private var states: [DisplayCaptureStreamConfigurationState] = []

    func record(_ state: DisplayCaptureStreamConfigurationState) {
        states.append(state)
    }

    func snapshot() -> [DisplayCaptureStreamConfigurationState] {
        states
    }
}

private struct StreamConfigurationCoordinatorTestError: Error {}

private actor StreamConfigurationFailureController {
    private var shouldFailNext = true
    private var appliedStates: [DisplayCaptureStreamConfigurationState] = []

    func apply(_ state: DisplayCaptureStreamConfigurationState) throws {
        if shouldFailNext {
            shouldFailNext = false
            throw StreamConfigurationCoordinatorTestError()
        }
        appliedStates.append(state)
    }

    func snapshot() -> [DisplayCaptureStreamConfigurationState] {
        appliedStates
    }
}

struct DisplayCaptureProfileStateMachineTests {
    @Test func desiredProfileMatchesPreviewAndSharingDemand() {
        #expect(
            DisplayCaptureProfileStateMachine.desiredProfile(
                for: makeDemand(attachedPreviewSinkCount: 1)
            ) == .previewOnly
        )
        #expect(
            DisplayCaptureProfileStateMachine.desiredProfile(
                for: makeDemand(shareTokenCount: 1)
            ) == .shareOnly
        )
        #expect(
            DisplayCaptureProfileStateMachine.desiredProfile(
                for: makeDemand(attachedPreviewSinkCount: 2, shareTokenCount: 1)
            ) == .mixed
        )
        #expect(
            DisplayCaptureProfileStateMachine.desiredProfile(
                for: makeDemand()
            ) == nil
        )
    }

    @Test func demandSnapshotComputesDerivedState() {
        let demand = makeDemand(
            attachedPreviewSinkCount: 1,
            shareTokenCount: 1,
            previewShowsCursor: false,
            shareCursorOverrideCount: 2,
            performanceMode: .smooth
        )

        #expect(demand.desiredProfile == .mixed)
        #expect(demand.showsCursor)
        #expect(demand.isEmpty == false)
    }

    @Test func previewFrameRateKeepsHighRefreshAndPreservesFallback() {
        #expect(DisplayCaptureSession.clampedPreviewFramesPerSecond(for: 144) == 144)
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
            ) == .fps60
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
        #expect(
            DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
                for: .shareOnly,
                performanceMode: .automatic,
                sourceFramesPerSecond: 90
            ).framesPerSecond == 90
        )
        #expect(
            DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
                for: .mixed,
                performanceMode: .smooth,
                sourceFramesPerSecond: 120
            ).framesPerSecond == 120
        )
        #expect(
            DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
                for: .mixed,
                performanceMode: .powerEfficient,
                sourceFramesPerSecond: 120
            ) == .fps30
        )
    }

    @Test func captureSizeContextAppliesSharedPixelBudgetByPerformanceMode() {
        let context = DisplayCaptureSizeContext(
            logicalSize: DisplayCaptureDimensions(width: 1_920, height: 1_080),
            physicalSize: DisplayCaptureDimensions(width: 3_840, height: 2_160)
        )

        #expect(context.captureSize(for: .previewOnly, performanceMode: .automatic) == DisplayCaptureDimensions(width: 3_840, height: 2_160))
        #expect(context.captureSize(for: .shareOnly, performanceMode: .automatic) == DisplayCaptureDimensions(width: 3_840, height: 2_160))
        #expect(context.captureSize(for: .mixed, performanceMode: .automatic) == DisplayCaptureDimensions(width: 3_840, height: 2_160))
        #expect(context.captureSize(for: .shareOnly, performanceMode: .powerEfficient) == DisplayCaptureDimensions(width: 1_920, height: 1_080))
        #expect(context.captureSize(for: .shareOnly, performanceMode: .smooth) == DisplayCaptureDimensions(width: 3_840, height: 2_160))
    }

    @Test func performanceModeUpdateRecomputesCommittedMixedConfiguration() {
        var coordinator = DisplayCaptureConfigurationCoordinatorState(
            committedConfiguration: .init(profile: .mixed, frameRateTier: .fps45),
            demand: makeDemand(attachedPreviewSinkCount: 1, shareTokenCount: 1)
        )

        let smoothDecision = coordinator.updateDemand(
            makeDemand(
                attachedPreviewSinkCount: 1,
                shareTokenCount: 1,
                performanceMode: .smooth
            ),
            nowNs: 1,
            minimumDwellNanoseconds: 0
        )
        switch smoothDecision {
        case .applyNow(let configuration):
            #expect(configuration.profile == .mixed)
            #expect(configuration.frameRateTier == .fps60)
        default:
            Issue.record("Expected smooth mode update to promote mixed configuration to 60fps, got \(String(describing: smoothDecision))")
        }

        let followUpDecision = coordinator.finishAppliedTransition(
            at: 2,
            minimumDwellNanoseconds: 0
        )
        #expect(followUpDecision == .noChange)

        let powerDecision = coordinator.updateDemand(
            makeDemand(
                attachedPreviewSinkCount: 1,
                shareTokenCount: 1,
                performanceMode: .powerEfficient
            ),
            nowNs: 3,
            minimumDwellNanoseconds: 0
        )
        switch powerDecision {
        case .applyNow(let configuration):
            #expect(configuration.profile == .mixed)
            #expect(configuration.frameRateTier == .fps30)
        default:
            Issue.record("Expected power efficient mode update to reduce mixed configuration to 30fps, got \(String(describing: powerDecision))")
        }
    }

    @Test func performanceModeUpdateRecomputesSharedCaptureSize() {
        let context = DisplayCaptureSizeContext(
            logicalSize: DisplayCaptureDimensions(width: 1_920, height: 1_080),
            physicalSize: DisplayCaptureDimensions(width: 3_840, height: 2_160)
        )
        var coordinator = DisplayCaptureConfigurationCoordinatorState(
            committedConfiguration: .init(
                profile: .mixed,
                frameRateTier: .fps60,
                captureSize: DisplayCaptureDimensions(width: 2_560, height: 1_440)
            ),
            demand: makeDemand(attachedPreviewSinkCount: 1, shareTokenCount: 1),
            captureSizeContext: context
        )

        let smoothDecision = coordinator.updateDemand(
            makeDemand(
                attachedPreviewSinkCount: 1,
                shareTokenCount: 1,
                performanceMode: .smooth
            ),
            nowNs: 1,
            minimumDwellNanoseconds: 0
        )
        switch smoothDecision {
        case .applyNow(let configuration):
            #expect(configuration.profile == .mixed)
            #expect(configuration.frameRateTier == .fps60)
            #expect(configuration.captureSize == DisplayCaptureDimensions(width: 3_840, height: 2_160))
        default:
            Issue.record("Expected smooth mode update to apply full capture size, got \(String(describing: smoothDecision))")
        }

        _ = coordinator.finishAppliedTransition(
            at: 2,
            minimumDwellNanoseconds: 0
        )

        let powerDecision = coordinator.updateDemand(
            makeDemand(
                attachedPreviewSinkCount: 1,
                shareTokenCount: 1,
                performanceMode: .powerEfficient
            ),
            nowNs: 3,
            minimumDwellNanoseconds: 0
        )
        switch powerDecision {
        case .applyNow(let configuration):
            #expect(configuration.profile == .mixed)
            #expect(configuration.frameRateTier == .fps30)
            #expect(configuration.captureSize == DisplayCaptureDimensions(width: 1_920, height: 1_080))
        default:
            Issue.record("Expected power mode update to apply budgeted capture size, got \(String(describing: powerDecision))")
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

    @Test func streamConfigurationCoordinatorUpdatesCaptureDimensionsFromDemandConfiguration() async throws {
        let recorder = StreamConfigurationRecorder()
        let coordinator = DisplayCaptureStreamConfigurationCoordinator(
            initialState: makeTestStreamConfigurationState(),
            applier: { state in
                await recorder.record(state)
            }
        )

        let changed = try await coordinator.applyDemandDrivenConfiguration(
            .init(
                profile: .mixed,
                frameRateTier: .fps60,
                captureSize: DisplayCaptureDimensions(width: 2_560, height: 1_440)
            )
        )
        let committedState = await coordinator.committedStateSnapshot()

        #expect(changed)
        #expect(committedState == makeTestStreamConfigurationState(width: 2_560, height: 1_440, frameRateTier: .fps60))
        #expect(await recorder.snapshot() == [makeTestStreamConfigurationState(width: 2_560, height: 1_440, frameRateTier: .fps60)])
    }

    @Test func streamConfigurationCoordinatorPreservesOverlappingChanges() async throws {
        let gate = StreamConfigurationApplyGate()
        let recorder = StreamConfigurationRecorder()
        let coordinator = DisplayCaptureStreamConfigurationCoordinator(
            initialState: makeTestStreamConfigurationState(),
            applier: { state in
                await recorder.record(state)
                await gate.enter()
            }
        )

        let firstTask = Task {
            try await coordinator.applyImmediateDemand(
                makeDemand(previewShowsCursor: true)
            )
        }
        await gate.waitForFirstEntry()

        let secondTask = Task {
            try await coordinator.applyDemandDrivenConfiguration(
                .init(profile: .mixed, frameRateTier: .fps30)
            )
        }

        await gate.open()

        let firstChanged = try await firstTask.value
        let secondChanged = try await secondTask.value
        let committedState = await coordinator.committedStateSnapshot()

        #expect(firstChanged)
        #expect(secondChanged)
        #expect(committedState == makeTestStreamConfigurationState(frameRateTier: .fps30, previewShowsCursor: true))
        #expect(
            await recorder.snapshot() == [
                makeTestStreamConfigurationState(previewShowsCursor: true),
                makeTestStreamConfigurationState(frameRateTier: .fps30, previewShowsCursor: true)
            ]
        )
    }

    @Test func streamConfigurationCoordinatorRecoversFromFailedApplyUsingCommittedState() async throws {
        let failureController = StreamConfigurationFailureController()
        let coordinator = DisplayCaptureStreamConfigurationCoordinator(
            initialState: makeTestStreamConfigurationState(),
            applier: { state in
                try await failureController.apply(state)
            }
        )

        await #expect(throws: Error.self) {
            try await coordinator.applyImmediateDemand(
                makeDemand(previewShowsCursor: true)
            )
        }

        let retryChanged = try await coordinator.applyDemandDrivenConfiguration(
            .init(profile: .mixed, frameRateTier: .fps30)
        )
        let committedState = await coordinator.committedStateSnapshot()

        #expect(retryChanged)
        #expect(committedState == makeTestStreamConfigurationState(frameRateTier: .fps30))
        #expect(
            await failureController.snapshot() == [
                makeTestStreamConfigurationState(frameRateTier: .fps30)
            ]
        )
    }
}
