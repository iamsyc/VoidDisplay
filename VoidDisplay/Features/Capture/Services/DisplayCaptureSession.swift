import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization

private final class DisplayStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    nonisolated(unsafe) weak var session: DisplayCaptureSession?

    nonisolated override init() {
        super.init()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        session?.handle(sampleBuffer: sampleBuffer, type: type)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            AppErrorMapper.logFailure("Screen capture stream stopped", error: error, logger: AppLog.capture)
        }
    }
}

private struct DisplayCaptureMetrics: Sendable {
    var currentProfile: DisplayCaptureProfile?
    var currentFrameRateTier: DisplayCaptureFrameRateTier?
    var receivedFrameCount: UInt64 = 0
    var profileReconfigurationCount: UInt64 = 0
    var cursorOverrideReconfigurationCount: UInt64 = 0

    nonisolated func snapshot() -> DisplayCaptureMetricsSnapshot {
        .init(
            currentProfile: currentProfile,
            currentFrameRateTier: currentFrameRateTier,
            receivedFrameCount: receivedFrameCount,
            profileReconfigurationCount: profileReconfigurationCount,
            cursorOverrideReconfigurationCount: cursorOverrideReconfigurationCount
        )
    }
}

final class DisplayCaptureSession: @unchecked Sendable, DisplayCaptureSessioning {
    private struct StreamConfigurationState: Sendable {
        let width: Int
        let height: Int
        let maximumPreviewFramesPerSecond: Int
        let queueDepth: Int
        let capturesAudio: Bool
        let pixelFormat: OSType
        var profile: DisplayCaptureProfile
        var frameRateTier: DisplayCaptureFrameRateTier
        var previewShowsCursor: Bool
        var shareCursorOverrideCount: Int

        nonisolated var minimumFrameInterval: CMTime {
            let framesPerSecond = DisplayCaptureSession.captureFramesPerSecond(
                for: profile,
                frameRateTier: frameRateTier,
                maximumPreviewFramesPerSecond: maximumPreviewFramesPerSecond
            )
            return CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(framesPerSecond))))
        }
    }

    private struct DemandState {
        var configurationCoordinator: DisplayCaptureConfigurationCoordinatorState
        var taskLifetime = DisplayCaptureTaskLifetimeState()
        var pendingTaskNonce: UInt64 = 0
        var pendingConfigurationTask: Task<Void, Never>?
        var activeApplyTask: Task<Void, Never>?
    }

    nonisolated private static let minimumConfigurationDwellNanoseconds: UInt64 = 5_000_000_000

    nonisolated let displayID: CGDirectDisplayID
    nonisolated let sessionHub: WebRTCSessionHub

    nonisolated(unsafe) private let stream: SCStream
    private let output = DisplayStreamOutput()
    nonisolated private let captureQueue: DispatchQueue
    nonisolated private let fanout = DisplaySampleFanout()
    nonisolated private let metrics = Mutex(DisplayCaptureMetrics())
    nonisolated private let configurationState: Mutex<StreamConfigurationState>
    nonisolated private let demandState: Mutex<DemandState>

    nonisolated init(
        display: SCDisplay,
        initialProfile: DisplayCaptureProfile = .previewOnly,
        initialPerformanceMode: CapturePerformanceMode = .automatic
    ) async throws {
        self.displayID = display.displayID
        self.captureQueue = DispatchQueue(
            label: "com.developerchen.voiddisplay.capture.\(display.displayID)",
            qos: .userInitiated
        )

        let state = try await Self.makeStreamConfigurationState(
            display: display,
            showsCursor: false,
            initialProfile: initialProfile,
            initialPerformanceMode: initialPerformanceMode
        )
        let config = Self.makeStreamConfiguration(from: state)
        let filter = try await Self.makeContentFilter(display: display)
        self.stream = SCStream(filter: filter, configuration: config, delegate: output)
        self.sessionHub = WebRTCSessionHub()
        self.configurationState = Mutex(state)
        self.demandState = Mutex(
            DemandState(
                configurationCoordinator: DisplayCaptureConfigurationCoordinatorState(
                    committedConfiguration: .init(
                        profile: state.profile,
                        frameRateTier: state.frameRateTier
                    ),
                    performanceMode: initialPerformanceMode
                )
            )
        )
        self.metrics.withLock {
            $0.currentProfile = state.profile
            $0.currentFrameRateTier = state.frameRateTier
        }

        output.session = self

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.attachPreviewSink(sink)
        scheduleDemandUpdate { state in
            state.previewSinkCount += 1
        }
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.detachPreviewSink(sink)
        scheduleDemandUpdate { state in
            state.previewSinkCount = max(
                0,
                state.previewSinkCount - 1
            )
        }
    }

    nonisolated func stopSharing() {
        sessionHub.stopSharing()
    }

    nonisolated func setPreviewShowsCursor(_ showsCursor: Bool) async throws {
        let updatedState = configurationState.withLock { state -> StreamConfigurationState in
            guard state.previewShowsCursor != showsCursor else { return state }
            var copy = state
            copy.previewShowsCursor = showsCursor
            return copy
        }
        guard updatedState.previewShowsCursor == showsCursor else { return }
        metrics.withLock { $0.cursorOverrideReconfigurationCount &+= 1 }
        try await applyStreamConfiguration(updatedState)
    }

    nonisolated func retainShareCursorOverride() async throws {
        let updatedState = configurationState.withLock { state -> StreamConfigurationState in
            var copy = state
            copy.shareCursorOverrideCount += 1
            return copy
        }
        metrics.withLock { $0.cursorOverrideReconfigurationCount &+= 1 }
        try await applyStreamConfiguration(updatedState)
    }

    nonisolated func releaseShareCursorOverride() async throws {
        let updatedState = configurationState.withLock { state -> StreamConfigurationState in
            var copy = state
            copy.shareCursorOverrideCount = max(0, copy.shareCursorOverrideCount - 1)
            return copy
        }
        metrics.withLock { $0.cursorOverrideReconfigurationCount &+= 1 }
        try await applyStreamConfiguration(updatedState)
    }

    nonisolated func setSharingActive(_ isActive: Bool) async throws {
        scheduleDemandUpdate { state in
            state.sharingActive = isActive
        }
    }

    nonisolated func setPerformanceMode(_ mode: CapturePerformanceMode) async throws {
        schedulePerformanceModeUpdate(mode)
    }

    nonisolated func reportPreviewPerformanceSample(_ sample: DisplayPreviewPerformanceSample) {
        schedulePreviewPerformanceSample(sample)
    }

    nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot {
        metrics.withLock { $0.snapshot() }
    }

    nonisolated private func applyStreamConfiguration(_ updatedState: StreamConfigurationState) async throws {
        try await stream.updateConfiguration(Self.makeStreamConfiguration(from: updatedState))
        configurationState.withLock { state in
            state.profile = updatedState.profile
            state.frameRateTier = updatedState.frameRateTier
            state.previewShowsCursor = updatedState.previewShowsCursor
            state.shareCursorOverrideCount = updatedState.shareCursorOverrideCount
        }
    }

    nonisolated func stop() async {
        demandState.withLock { state in
            _ = state.taskLifetime.invalidateAllTasks()
            state.pendingConfigurationTask?.cancel()
            state.pendingConfigurationTask = nil
            state.activeApplyTask?.cancel()
            state.activeApplyTask = nil
        }
        stopSharing()
        try? await stream.stopCapture()
    }

    nonisolated func handle(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        metrics.withLock { $0.receivedFrameCount &+= 1 }

        fanout.publishPreviewFrame(sampleBuffer)

        guard sessionHub.hasDemand else { return }
        let ptsUs = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        sessionHub.submitFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
    }

    nonisolated private func scheduleDemandUpdate(
        _ mutation: (inout DisplayCaptureConfigurationCoordinatorState) -> Void
    ) {
        scheduleConfigurationDecision { state in
            state.configurationCoordinator.mutateDemand(
                nowNs: Self.currentTimeNanoseconds(),
                minimumDwellNanoseconds: Self.minimumConfigurationDwellNanoseconds,
                mutation: mutation
            )
        }
    }

    nonisolated private func schedulePerformanceModeUpdate(_ mode: CapturePerformanceMode) {
        scheduleConfigurationDecision { state in
            state.configurationCoordinator.updatePerformanceMode(
                mode,
                nowNs: Self.currentTimeNanoseconds(),
                minimumDwellNanoseconds: Self.minimumConfigurationDwellNanoseconds
            )
        }
    }

    nonisolated private func schedulePreviewPerformanceSample(_ sample: DisplayPreviewPerformanceSample) {
        scheduleConfigurationDecision { state in
            state.configurationCoordinator.recordPreviewPerformanceSample(
                sample,
                nowNs: Self.currentTimeNanoseconds(),
                minimumDwellNanoseconds: Self.minimumConfigurationDwellNanoseconds
            )
        }
    }

    nonisolated private func scheduleConfigurationDecision(
        _ decisionProvider: (inout DemandState) -> DisplayCaptureConfigurationDecision
    ) {
        let decision = demandState.withLock { state -> (DisplayCaptureConfigurationDecision, UInt64) in
            state.pendingConfigurationTask?.cancel()
            state.pendingConfigurationTask = nil
            state.pendingTaskNonce &+= 1
            let decision = decisionProvider(&state)
            return (decision, state.pendingTaskNonce)
        }
        handleConfigurationDecision(decision.0, schedulingNonce: decision.1)
    }

    nonisolated private func handleConfigurationDecision(
        _ decision: DisplayCaptureConfigurationDecision,
        schedulingNonce: UInt64
    ) {
        switch decision {
        case .noChange:
            return
        case .applyNow(let configuration):
            let executionGeneration = demandState.withLock { $0.taskLifetime.currentGeneration }
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                try? await self.applyDemandDrivenConfiguration(
                    configuration: configuration,
                    executionGeneration: executionGeneration
                )
            }
            demandState.withLock { state in
                if state.taskLifetime.allowsExecution(for: executionGeneration) {
                    state.activeApplyTask = task
                } else {
                    task.cancel()
                }
            }
        case .applyAfter(_, let delayNanoseconds):
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                self?.resumeDemandDrivenConfigurationEvaluation(schedulingNonce: schedulingNonce)
            }
            demandState.withLock { state in
                if state.pendingTaskNonce == schedulingNonce {
                    state.pendingConfigurationTask = task
                } else {
                    task.cancel()
                }
            }
        }
    }

    nonisolated private func resumeDemandDrivenConfigurationEvaluation(schedulingNonce: UInt64) {
        let decision = demandState.withLock { state -> (DisplayCaptureConfigurationDecision, UInt64)? in
            guard state.pendingTaskNonce == schedulingNonce else {
                return nil
            }
            state.pendingConfigurationTask = nil
            state.pendingTaskNonce &+= 1
            let decision = state.configurationCoordinator.resumeScheduledTransition(
                nowNs: Self.currentTimeNanoseconds(),
                minimumDwellNanoseconds: Self.minimumConfigurationDwellNanoseconds
            )
            return (decision, state.pendingTaskNonce)
        }
        guard let decision else { return }
        handleConfigurationDecision(decision.0, schedulingNonce: decision.1)
    }

    nonisolated private func applyDemandDrivenConfiguration(
        configuration: DisplayCaptureConfiguration,
        executionGeneration: UInt64
    ) async throws {
        guard isExecutionAllowed(for: executionGeneration) else { return }

        let updatedState = configurationState.withLock { state -> StreamConfigurationState? in
            guard state.profile != configuration.profile || state.frameRateTier != configuration.frameRateTier else {
                return nil
            }
            var copy = state
            copy.profile = configuration.profile
            copy.frameRateTier = configuration.frameRateTier
            return copy
        }
        guard let updatedState else {
            finishDemandDrivenConfigurationFailure(executionGeneration: executionGeneration)
            return
        }

        do {
            try Task.checkCancellation()
            guard isExecutionAllowed(for: executionGeneration) else { return }

            try await stream.updateConfiguration(Self.makeStreamConfiguration(from: updatedState))
            guard isExecutionAllowed(for: executionGeneration) else { return }

            configurationState.withLock { state in
                state.profile = updatedState.profile
                state.frameRateTier = updatedState.frameRateTier
                state.previewShowsCursor = updatedState.previewShowsCursor
                state.shareCursorOverrideCount = updatedState.shareCursorOverrideCount
            }
        } catch is CancellationError {
            finishDemandDrivenConfigurationFailure(executionGeneration: executionGeneration)
            return
        } catch {
            finishDemandDrivenConfigurationFailure(executionGeneration: executionGeneration)
            AppErrorMapper.logFailure("Update capture configuration", error: error, logger: AppLog.capture)
            return
        }

        guard isExecutionAllowed(for: executionGeneration) else { return }

        metrics.withLock { metrics in
            metrics.currentProfile = configuration.profile
            metrics.currentFrameRateTier = configuration.frameRateTier
            metrics.profileReconfigurationCount &+= 1
        }

        let decision = demandState.withLock { state -> (DisplayCaptureConfigurationDecision, UInt64)? in
            guard state.taskLifetime.allowsExecution(for: executionGeneration) else {
                return nil
            }
            state.pendingConfigurationTask?.cancel()
            state.pendingConfigurationTask = nil
            state.activeApplyTask = nil
            state.pendingTaskNonce &+= 1
            let decision = state.configurationCoordinator.finishAppliedTransition(
                at: Self.currentTimeNanoseconds(),
                minimumDwellNanoseconds: Self.minimumConfigurationDwellNanoseconds
            )
            return (decision, state.pendingTaskNonce)
        }
        guard let decision else { return }
        handleConfigurationDecision(decision.0, schedulingNonce: decision.1)
    }

    nonisolated private func isExecutionAllowed(for generation: UInt64) -> Bool {
        demandState.withLock { state in
            state.taskLifetime.allowsExecution(for: generation)
        }
    }

    nonisolated private func finishDemandDrivenConfigurationFailure(executionGeneration: UInt64) {
        demandState.withLock { state in
            guard state.taskLifetime.allowsExecution(for: executionGeneration) else { return }
            state.activeApplyTask = nil
            state.configurationCoordinator.failAppliedTransition()
        }
    }
}

extension DisplayCaptureSession {
    nonisolated static func captureFramesPerSecond(
        for profile: DisplayCaptureProfile,
        frameRateTier: DisplayCaptureFrameRateTier,
        maximumPreviewFramesPerSecond: Int
    ) -> Int {
        switch profile {
        case .previewOnly:
            return min(maximumPreviewFramesPerSecond, frameRateTier.framesPerSecond)
        case .shareOnly:
            return frameRateTier.framesPerSecond
        case .mixed:
            return frameRateTier.framesPerSecond
        }
    }

    nonisolated static func microseconds(from time: CMTime) -> UInt64 {
        guard time.isValid, !time.isIndefinite, time.seconds.isFinite else { return 0 }
        let scaled = CMTimeConvertScale(time, timescale: 1_000_000, method: .default)
        return scaled.value > 0 ? UInt64(scaled.value) : 0
    }

    nonisolated private static func currentTimeNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    nonisolated static func clampedPreviewFramesPerSecond(for refreshRate: Double) -> Int {
        let normalizedRefreshRate = refreshRate > 0 ? refreshRate : 60.0
        return max(1, Int(min(normalizedRefreshRate, 60.0).rounded()))
    }

    nonisolated private static func makeStreamConfigurationState(
        display: SCDisplay,
        showsCursor: Bool,
        initialProfile: DisplayCaptureProfile,
        initialPerformanceMode: CapturePerformanceMode
    ) async throws -> StreamConfigurationState {
        let displayMode = CGDisplayCopyDisplayMode(display.displayID)

        let captureSize = preferredCaptureSize(display: display, displayMode: displayMode)
        let previewFramesPerSecond = clampedPreviewFramesPerSecond(for: displayMode?.refreshRate ?? 60.0)
        let initialFrameRateTier = DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
            for: initialProfile,
            performanceMode: initialPerformanceMode
        )

        let state = StreamConfigurationState(
            width: captureSize.width,
            height: captureSize.height,
            maximumPreviewFramesPerSecond: previewFramesPerSecond,
            queueDepth: 2,
            capturesAudio: false,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            profile: initialProfile,
            frameRateTier: initialFrameRateTier,
            previewShowsCursor: showsCursor,
            shareCursorOverrideCount: 0
        )
        AppLog.capture.notice(
            "Capture config display=\(display.displayID, privacy: .public) size=\(captureSize.width)x\(captureSize.height, privacy: .public)"
        )
        return state
    }

    nonisolated private static func makeStreamConfiguration(
        from state: StreamConfigurationState
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = state.width
        config.height = state.height
        config.minimumFrameInterval = state.minimumFrameInterval
        config.queueDepth = state.queueDepth
        config.showsCursor = state.shareCursorOverrideCount > 0 || state.previewShowsCursor
        config.capturesAudio = state.capturesAudio
        config.pixelFormat = state.pixelFormat
        return config
    }

    nonisolated private static func preferredCaptureSize(
        display: SCDisplay,
        displayMode: CGDisplayMode?
    ) -> (width: Int, height: Int) {
        let modePixelWidth = displayMode.map { Int($0.pixelWidth) } ?? display.width
        let modePixelHeight = displayMode.map { Int($0.pixelHeight) } ?? display.height
        let modeLogicalWidth = displayMode.map { $0.width } ?? modePixelWidth
        let modeLogicalHeight = displayMode.map { $0.height } ?? modePixelHeight
        let backingScale = screenBackingScaleFactor(for: display.displayID)

        let scaledLogicalWidth = max(1, Int((CGFloat(modeLogicalWidth) * backingScale).rounded()))
        let scaledLogicalHeight = max(1, Int((CGFloat(modeLogicalHeight) * backingScale).rounded()))

        return (
            width: max(modePixelWidth, scaledLogicalWidth),
            height: max(modePixelHeight, scaledLogicalHeight)
        )
    }

    nonisolated private static func screenBackingScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[key] as? NSNumber else { return false }
            return number.uint32Value == displayID
        }) else {
            return 1.0
        }
        return max(1.0, screen.backingScaleFactor)
    }

    nonisolated private static func makeContentFilter(
        display: SCDisplay
    ) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        let excludedApps = content.applications.filter { app in
            Bundle.main.bundleIdentifier == app.bundleIdentifier
        }
        return SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
    }
}
