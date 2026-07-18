import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization

private final class DisplayCaptureStreamReference: @unchecked Sendable {
    let value: SCStream

    init(_ value: SCStream) {
        self.value = value
    }
}

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
    package var currentProfile: DisplayCaptureProfile?
    package var currentFrameRateTier: DisplayCaptureFrameRateTier?
    package var receivedFrameCount: UInt64 = 0
    package var profileReconfigurationCount: UInt64 = 0
    package var cursorOverrideReconfigurationCount: UInt64 = 0

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

private final class DisplayCaptureMetricsStore: Sendable {
    package let value = Mutex(DisplayCaptureMetrics())
}
package nonisolated struct DisplayCaptureStreamConfigurationState: Sendable, Equatable {
    package var width: Int
    package var height: Int
    package let maximumPreviewFramesPerSecond: Int
    package let queueDepth: Int
    package let capturesAudio: Bool
    package let pixelFormat: OSType
    package var profile: DisplayCaptureProfile
    package var frameRateTier: DisplayCaptureFrameRateTier
    package var previewShowsCursor: Bool
    package var shareCursorOverrideCount: Int

    nonisolated var minimumFrameInterval: CMTime {
        let framesPerSecond = DisplayCaptureSession.captureFramesPerSecond(
            for: profile,
            frameRateTier: frameRateTier,
            maximumPreviewFramesPerSecond: maximumPreviewFramesPerSecond
        )
        return CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(framesPerSecond))))
    }
}

private nonisolated func makeDisplayCaptureStreamConfiguration(
    from state: DisplayCaptureStreamConfigurationState
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
package actor DisplayCaptureStreamConfigurationCoordinator {
    package typealias TestApplier = @Sendable (DisplayCaptureStreamConfigurationState) async throws -> Void

    private struct Waiter {
        let revision: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let stream: SCStream?
    private let testApplier: TestApplier?
    private var committedState: DisplayCaptureStreamConfigurationState
    private var desiredState: DisplayCaptureStreamConfigurationState
    private var committedRevision: UInt64 = 0
    private var nextRevision: UInt64 = 0
    private var pendingRevision: UInt64?
    private var failedThroughRevision: UInt64?
    private var lastFailure: (any Error)?
    private var flushTask: Task<Void, Never>?
    private var waiters: [UUID: Waiter] = [:]

    package init(
        stream: SCStream,
        initialState: DisplayCaptureStreamConfigurationState
    ) {
        self.stream = stream
        self.testApplier = nil
        self.committedState = initialState
        self.desiredState = initialState
    }

    package init(
        initialState: DisplayCaptureStreamConfigurationState,
        applier: @escaping TestApplier
    ) {
        self.stream = nil
        self.testApplier = applier
        self.committedState = initialState
        self.desiredState = initialState
    }

    package func applyImmediateDemand(_ demand: DisplayCaptureDemandSnapshot) async throws -> Bool {
        try await applyMutation { state in
            state.previewShowsCursor = demand.previewShowsCursor
            state.shareCursorOverrideCount = demand.shareCursorOverrideCount
        }
    }

    package func applyDemandDrivenConfiguration(_ configuration: DisplayCaptureConfiguration) async throws -> Bool {
        try await applyMutation { state in
            state.width = configuration.captureSize.width
            state.height = configuration.captureSize.height
            state.profile = configuration.profile
            state.frameRateTier = configuration.frameRateTier
        }
    }

    package func committedStateSnapshot() -> DisplayCaptureStreamConfigurationState {
        committedState
    }

    package func cancelPending(error: any Error = CancellationError()) {
        flushTask?.cancel()
        flushTask = nil

        guard let pendingRevision else { return }
        desiredState = committedState
        self.pendingRevision = nil
        failedThroughRevision = pendingRevision
        lastFailure = error
        failWaiters(
            upTo: pendingRevision,
            error: error
        )
    }

    private func applyMutation(
        _ mutation: (inout DisplayCaptureStreamConfigurationState) -> Void
    ) async throws -> Bool {
        var nextState = desiredState
        mutation(&nextState)

        guard nextState != desiredState else {
            if let pendingRevision {
                try await waitForResolution(of: pendingRevision)
            }
            return false
        }

        desiredState = nextState
        nextRevision &+= 1
        let targetRevision = nextRevision
        pendingRevision = targetRevision
        if flushTask == nil {
            flushTask = Task {
                await self.flushLoop()
            }
        }
        try await waitForResolution(of: targetRevision)
        return true
    }

    private func waitForResolution(of revision: UInt64) async throws {
        if committedRevision >= revision {
            return
        }
        if let failedThroughRevision,
           failedThroughRevision >= revision,
           let lastFailure {
            throw lastFailure
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if committedRevision >= revision {
                    continuation.resume(returning: ())
                    return
                }
                if let failedThroughRevision,
                   failedThroughRevision >= revision,
                   let lastFailure {
                    continuation.resume(throwing: lastFailure)
                    return
                }
                waiters[waiterID] = Waiter(
                    revision: revision,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func flushLoop() async {
        while let pendingRevision {
            let stateToApply = desiredState
            let revisionToApply = pendingRevision

            do {
                try Task.checkCancellation()
                try await applyState(stateToApply)
            } catch {
                let failedThrough = self.pendingRevision ?? revisionToApply
                desiredState = committedState
                self.pendingRevision = nil
                failedThroughRevision = failedThrough
                lastFailure = error
                flushTask = nil
                failWaiters(
                    upTo: failedThrough,
                    error: error
                )
                return
            }

            committedState = stateToApply
            committedRevision = revisionToApply
            resumeWaiters(upTo: revisionToApply)

            if self.pendingRevision == revisionToApply {
                desiredState = committedState
                self.pendingRevision = nil
            }
        }

        flushTask = nil
    }

    private func applyState(_ state: DisplayCaptureStreamConfigurationState) async throws {
        if let stream {
            try await stream.updateConfiguration(makeDisplayCaptureStreamConfiguration(from: state))
            return
        }
        if let testApplier {
            try await testApplier(state)
            return
        }
        preconditionFailure("DisplayCaptureStreamConfigurationCoordinator requires an applier")
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeWaiters(upTo revision: UInt64) {
        let matchingIDs = waiters.compactMap { id, waiter in
            waiter.revision <= revision ? id : nil
        }
        for id in matchingIDs {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation.resume(returning: ())
        }
    }

    private func failWaiters(
        upTo revision: UInt64,
        error: any Error
    ) {
        let matchingIDs = waiters.compactMap { id, waiter in
            waiter.revision <= revision ? id : nil
        }
        for id in matchingIDs {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation.resume(throwing: error)
        }
    }
}
package final class DisplayCaptureSession: @unchecked Sendable, DisplayCaptureSessioning {
    nonisolated private static let minimumConfigurationDwellNanoseconds: UInt64 = 5_000_000_000

    nonisolated let displayID: CGDirectDisplayID
    package nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer

    nonisolated(unsafe) private let stream: SCStream
    private let output = DisplayStreamOutput()
    nonisolated private let captureQueue: DispatchQueue
    nonisolated private let fanout = DisplaySampleFanout()
    nonisolated private let metrics: DisplayCaptureMetricsStore
    nonisolated private let streamConfigurationCoordinator: DisplayCaptureStreamConfigurationCoordinator
    nonisolated private let demandDriver: DisplayCaptureDemandDriver
    nonisolated private let streamActivity: DisplayCaptureStreamActivity
    nonisolated private let sourceVideoSpec: SourceVideoSpec

    nonisolated init(
        display: SCDisplay,
        initialProfile: DisplayCaptureProfile = .previewOnly,
        initialPerformanceMode: CapturePerformanceMode = .automatic,
        makeShareFrameConsumer: @Sendable () -> any DisplayShareFrameConsumer
    ) async throws {
        self.displayID = display.displayID
        self.captureQueue = DispatchQueue(
            label: "com.developerchen.voiddisplay.capture.\(display.displayID)",
            qos: .userInitiated
        )

        let displayMode = CGDisplayCopyDisplayMode(display.displayID)
        let captureSizeContext = Self.captureSizeContext(display: display, displayMode: displayMode)
        let state = try await Self.makeStreamConfigurationState(
            display: display,
            displayMode: displayMode,
            captureSizeContext: captureSizeContext,
            showsCursor: false,
            initialProfile: initialProfile,
            initialPerformanceMode: initialPerformanceMode
        )
        let config = makeDisplayCaptureStreamConfiguration(from: state)
        let filter = try await Self.makeContentFilter(display: display)
        let captureStream = SCStream(filter: filter, configuration: config, delegate: output)
        let sendableCaptureStream = DisplayCaptureStreamReference(captureStream)
        self.stream = captureStream
        self.shareFrameConsumer = makeShareFrameConsumer()
        self.sourceVideoSpec = captureSizeContext.sourceVideoSpec
        self.shareFrameConsumer.updateSourceVideoSpec(captureSizeContext.sourceVideoSpec)
        let metrics = DisplayCaptureMetricsStore()
        self.metrics = metrics
        let streamConfigurationCoordinator = DisplayCaptureStreamConfigurationCoordinator(
            stream: self.stream,
            initialState: state
        )
        self.streamConfigurationCoordinator = streamConfigurationCoordinator
        self.streamActivity = DisplayCaptureStreamActivity(
            start: { try await sendableCaptureStream.value.startCapture() },
            stop: { try await sendableCaptureStream.value.stopCapture() }
        )
        self.demandDriver = DisplayCaptureDemandDriver(
            initialConfiguration: .init(
                profile: state.profile,
                frameRateTier: state.frameRateTier,
                captureSize: DisplayCaptureDimensions(width: state.width, height: state.height)
            ),
            initialDemand: DisplayCaptureDemandSnapshot(
                performanceMode: initialPerformanceMode
            ),
            captureSizeContext: captureSizeContext,
            minimumDwellNanoseconds: Self.minimumConfigurationDwellNanoseconds,
            applyImmediateDemand: { demand in
                let changed = try await streamConfigurationCoordinator.applyImmediateDemand(demand)
                guard changed else { return false }
                metrics.value.withLock { $0.cursorOverrideReconfigurationCount &+= 1 }
                return true
            },
            applyConfiguration: { configuration in
                try await streamConfigurationCoordinator.applyDemandDrivenConfiguration(configuration)
            },
            onConfigurationApplied: { configuration in
                metrics.value.withLock { metrics in
                    metrics.currentProfile = configuration.profile
                    metrics.currentFrameRateTier = configuration.frameRateTier
                    metrics.profileReconfigurationCount &+= 1
                }
            },
            onConfigurationFailure: { error in
                AppErrorMapper.logFailure(
                    "Update capture configuration",
                    error: error,
                    logger: AppLog.capture
                )
            }
        )
        metrics.value.withLock {
            $0.currentProfile = state.profile
            $0.currentFrameRateTier = state.frameRateTier
        }
        output.session = self

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
    }

    package nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.attachPreviewSink(sink)
    }

    package nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.detachPreviewSink(sink)
    }

    package nonisolated func stopSharing() {
        shareFrameConsumer.stopSharing()
    }

    package nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        shareFrameConsumer.updateSourceVideoSpec(sourceVideoSpec)
        shareFrameConsumer.updatePerformanceMode(demand.performanceMode)
        try await demandDriver.setDemand(demand)
        try await streamActivity.setActive(!demand.isEmpty)
    }

    package nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot {
        metrics.value.withLock { $0.snapshot() }
    }

    package nonisolated func stop() async {
        demandDriver.cancelAll()
        await streamConfigurationCoordinator.cancelPending()
        stopSharing()
        do {
            try await streamActivity.stop()
        } catch {
            AppErrorMapper.logFailure(
                "Stop screen capture stream",
                error: error,
                logger: AppLog.capture,
                subsystem: .capture
            )
        }
    }

    nonisolated func handle(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        metrics.value.withLock { $0.receivedFrameCount &+= 1 }

        fanout.publishPreviewFrame(sampleBuffer)

        guard shareFrameConsumer.hasDemand else { return }
        let ptsUs = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        shareFrameConsumer.submitFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
    }
}

package extension DisplayCaptureSession {
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

    nonisolated static func sourceFramesPerSecond(for refreshRate: Double) -> Int {
        let normalizedRefreshRate = refreshRate > 0 ? refreshRate : 60.0
        return max(1, Int(normalizedRefreshRate.rounded()))
    }

    nonisolated private static func makeStreamConfigurationState(
        display: SCDisplay,
        displayMode: CGDisplayMode?,
        captureSizeContext: DisplayCaptureSizeContext,
        showsCursor: Bool,
        initialProfile: DisplayCaptureProfile,
        initialPerformanceMode: CapturePerformanceMode
    ) async throws -> DisplayCaptureStreamConfigurationState {
        let captureSize = captureSizeContext.captureSize(
            for: initialProfile,
            performanceMode: initialPerformanceMode
        )
        let previewFramesPerSecond = sourceFramesPerSecond(for: displayMode?.refreshRate ?? 60.0)
        let initialFrameRateTier = DisplayCaptureConfigurationStateMachine.defaultFrameRateTier(
            for: initialProfile,
            performanceMode: initialPerformanceMode,
            sourceFramesPerSecond: captureSizeContext.sourceVideoSpec.framesPerSecond
        )

        let state = DisplayCaptureStreamConfigurationState(
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
            "Capture config display=\(display.displayID, privacy: .public) size=\(captureSize.width)x\(captureSize.height, privacy: .public) logical=\(captureSizeContext.logicalSize.width)x\(captureSizeContext.logicalSize.height, privacy: .public) physical=\(captureSizeContext.physicalSize.width)x\(captureSizeContext.physicalSize.height, privacy: .public) sourceFps=\(captureSizeContext.sourceVideoSpec.framesPerSecond, privacy: .public)"
        )
        return state
    }

    nonisolated private static func captureSizeContext(
        display: SCDisplay,
        displayMode: CGDisplayMode?
    ) -> DisplayCaptureSizeContext {
        let modePixelWidth = displayMode.map { Int($0.pixelWidth) } ?? display.width
        let modePixelHeight = displayMode.map { Int($0.pixelHeight) } ?? display.height
        let modeLogicalWidth = displayMode.map { $0.width } ?? modePixelWidth
        let modeLogicalHeight = displayMode.map { $0.height } ?? modePixelHeight
        let backingScale = screenBackingScaleFactor(for: display.displayID)
        let sourceFramesPerSecond = sourceFramesPerSecond(for: displayMode?.refreshRate ?? 60.0)

        let scaledLogicalWidth = max(1, Int((CGFloat(modeLogicalWidth) * backingScale).rounded()))
        let scaledLogicalHeight = max(1, Int((CGFloat(modeLogicalHeight) * backingScale).rounded()))

        return DisplayCaptureSizeContext(
            logicalSize: DisplayCaptureDimensions(
                width: display.width > 0 ? display.width : modeLogicalWidth,
                height: display.height > 0 ? display.height : modeLogicalHeight
            ),
            physicalSize: DisplayCaptureDimensions(
                width: max(modePixelWidth, scaledLogicalWidth),
                height: max(modePixelHeight, scaledLogicalHeight)
            ),
            sourceFramesPerSecond: sourceFramesPerSecond
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
