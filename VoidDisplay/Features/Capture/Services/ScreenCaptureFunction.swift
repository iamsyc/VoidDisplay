import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization

// MARK: - Public Protocols & Value Types

protocol DisplayPreviewSink: AnyObject, Sendable {
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer)
}

nonisolated struct SendableDisplay: @unchecked Sendable {
    nonisolated(unsafe) let value: SCDisplay
    nonisolated let displayID: CGDirectDisplayID
    nonisolated let width: Int
    nonisolated let height: Int

    nonisolated init(_ value: SCDisplay) {
        self.value = value
        self.displayID = value.displayID
        self.width = value.width
        self.height = value.height
    }
}

protocol DisplayCaptureSessioning: AnyObject, Sendable {
    nonisolated var sessionHub: WebRTCSessionHub { get }
    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink)
    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink)
    nonisolated func stopSharing()
    nonisolated func stop() async
}

// MARK: - Preview Subscription

final class DisplayPreviewSubscription: Sendable {
    let displayID: CGDirectDisplayID
    let resolutionText: String

    private let session: any DisplayCaptureSessioning
    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)

    nonisolated init(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning,
        cancelClosure: @escaping @Sendable () -> Void
    ) {
        self.displayID = displayID
        self.resolutionText = resolutionText
        self.session = session
        cancelState.withLock { $0 = cancelClosure }
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        session.attachPreviewSink(sink)
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        session.detachPreviewSink(sink)
    }

    nonisolated func cancel() {
        let closure = cancelState.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        closure?()
    }

    deinit { cancel() }
}

// MARK: - Share Subscription

final class DisplayShareSubscription: Sendable {
    let displayID: CGDirectDisplayID
    let sessionHub: WebRTCSessionHub

    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)

    nonisolated init(
        displayID: CGDirectDisplayID,
        sessionHub: WebRTCSessionHub,
        cancelClosure: @escaping @Sendable () -> Void
    ) {
        self.displayID = displayID
        self.sessionHub = sessionHub
        cancelState.withLock { $0 = cancelClosure }
    }

    nonisolated func cancel() {
        let closure = cancelState.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        closure?()
    }

    deinit { cancel() }
}

// MARK: - Capture Registry

actor DisplayCaptureRegistry {
    enum SessionResourceState: Equatable {
        case initializing
        case active
        case draining
        case stopped
    }

    struct PreviewToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
        let displayID: CGDirectDisplayID
    }

    struct ShareToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
        let displayID: CGDirectDisplayID
    }

    private enum TokenKind: Sendable {
        case preview
        case share
    }

    private struct TokenRecord: Sendable {
        let kind: TokenKind
        let displayID: CGDirectDisplayID
    }

    struct SessionRecord {
        let session: any DisplayCaptureSessioning
        let resolutionText: String
        var state: SessionResourceState
        var previewTokens: Set<UUID>
        var shareTokens: Set<UUID>
    }

    private enum RegistryError: Error {
        case sessionUnavailable
    }

    typealias CaptureSessionFactory = @Sendable (SendableDisplay) async throws -> any DisplayCaptureSessioning

    static let shared = DisplayCaptureRegistry()

    private let captureSessionFactory: CaptureSessionFactory
    private var sessionsByDisplayID: [CGDirectDisplayID: SessionRecord] = [:]
    private var tokenOwnership: [UUID: TokenRecord] = [:]
    private var sessionCreationTasks: [CGDirectDisplayID: Task<SessionRecord, Error>] = [:]
    private var sessionDrainTasksByDisplayID: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var initializingDisplayIDs: Set<CGDirectDisplayID> = []

    init(
        captureSessionFactory: @escaping CaptureSessionFactory = { display in
            try await DisplayCaptureSession(display: display.value)
        }
    ) {
        self.captureSessionFactory = captureSessionFactory
    }

    // MARK: Acquire / Release

    func acquirePreview(display: SendableDisplay) async throws -> DisplayPreviewSubscription {
        let token = try await acquirePreviewToken(display: display)
        guard let record = sessionsByDisplayID[token.displayID] else {
            throw RegistryError.sessionUnavailable
        }
        return DisplayPreviewSubscription(
            displayID: token.displayID,
            resolutionText: record.resolutionText,
            session: record.session,
            cancelClosure: { [weak self] in
                guard let self else { return }
                Task { await self.release(token) }
            }
        )
    }

    func acquireShare(display: SendableDisplay) async throws -> DisplayShareSubscription {
        let token = try await acquireShareToken(display: display)
        guard let record = sessionsByDisplayID[token.displayID] else {
            throw RegistryError.sessionUnavailable
        }
        return DisplayShareSubscription(
            displayID: token.displayID,
            sessionHub: record.session.sessionHub,
            cancelClosure: { [weak self] in
                guard let self else { return }
                Task { await self.release(token) }
            }
        )
    }

    func acquirePreviewToken(display: SendableDisplay) async throws -> PreviewToken {
        let tokenID = try await acquireToken(display: display, kind: .preview)
        return PreviewToken(rawValue: tokenID, displayID: display.displayID)
    }

    func acquireShareToken(display: SendableDisplay) async throws -> ShareToken {
        let tokenID = try await acquireToken(display: display, kind: .share)
        return ShareToken(rawValue: tokenID, displayID: display.displayID)
    }

    func release(_ token: PreviewToken) async {
        await releaseToken(token.rawValue, expectedKind: .preview)
    }

    func release(_ token: ShareToken) async {
        await releaseToken(token.rawValue, expectedKind: .share)
    }

    func sessionState(for displayID: CGDirectDisplayID) -> SessionResourceState {
        if initializingDisplayIDs.contains(displayID) {
            return .initializing
        }
        return sessionsByDisplayID[displayID]?.state ?? .stopped
    }

    // MARK: Internal

    private func acquireToken(
        display: SendableDisplay,
        kind: TokenKind
    ) async throws -> UUID {
        try await ensureSessionExists(for: display)
        return try registerToken(displayID: display.displayID, kind: kind)
    }

#if DEBUG
    func installSessionForTesting(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning
    ) {
        sessionDrainTasksByDisplayID[displayID]?.cancel()
        sessionDrainTasksByDisplayID[displayID] = nil
        initializingDisplayIDs.remove(displayID)
        sessionsByDisplayID[displayID] = SessionRecord(
            session: session,
            resolutionText: resolutionText,
            state: .active,
            previewTokens: [],
            shareTokens: []
        )
    }

    func acquirePreviewTokenForTesting(displayID: CGDirectDisplayID) throws -> PreviewToken {
        let tokenID = try registerToken(displayID: displayID, kind: .preview)
        return PreviewToken(rawValue: tokenID, displayID: displayID)
    }

    func acquireShareTokenForTesting(displayID: CGDirectDisplayID) throws -> ShareToken {
        let tokenID = try registerToken(displayID: displayID, kind: .share)
        return ShareToken(rawValue: tokenID, displayID: displayID)
    }
#endif

    private func registerToken(displayID: CGDirectDisplayID, kind: TokenKind) throws -> UUID {
        let tokenID = UUID()
        guard var record = sessionsByDisplayID[displayID] else {
            throw RegistryError.sessionUnavailable
        }
        guard record.state != .draining else {
            throw RegistryError.sessionUnavailable
        }
        record.state = .active
        switch kind {
        case .preview:
            record.previewTokens.insert(tokenID)
        case .share:
            record.shareTokens.insert(tokenID)
        }
        sessionsByDisplayID[displayID] = record
        tokenOwnership[tokenID] = TokenRecord(kind: kind, displayID: displayID)
        return tokenID
    }

    private func ensureSessionExists(for display: SendableDisplay) async throws {
        let displayID = display.displayID
        if let existing = sessionsByDisplayID[displayID] {
            if existing.state != .draining {
                return
            }
            await waitForDrainCompletion(for: displayID)
            if let afterDrain = sessionsByDisplayID[displayID], afterDrain.state != .draining {
                return
            }
        }

        if let existingTask = sessionCreationTasks[displayID] {
            let record = try await existingTask.value
            storeInitializedSessionIfAbsent(record, for: displayID)
            return
        }

        let task = Task<SessionRecord, Error> { [captureSessionFactory] in
            let session = try await captureSessionFactory(display)
            return SessionRecord(
                session: session,
                resolutionText: "\(display.width) × \(display.height)",
                state: .active,
                previewTokens: [],
                shareTokens: []
            )
        }
        initializingDisplayIDs.insert(displayID)
        sessionCreationTasks[displayID] = task
        defer { sessionCreationTasks[displayID] = nil }

        do {
            let record = try await task.value
            storeInitializedSessionIfAbsent(record, for: displayID)
        } catch {
            initializingDisplayIDs.remove(displayID)
            throw error
        }
    }

    private func storeInitializedSessionIfAbsent(
        _ record: SessionRecord,
        for displayID: CGDirectDisplayID
    ) {
        initializingDisplayIDs.remove(displayID)
        guard sessionsByDisplayID[displayID] == nil else { return }
        sessionsByDisplayID[displayID] = record
    }

    private func releaseToken(_ tokenID: UUID, expectedKind: TokenKind) async {
        guard let ownership = tokenOwnership.removeValue(forKey: tokenID),
              ownership.kind == expectedKind else {
            return
        }
        guard var record = sessionsByDisplayID[ownership.displayID] else { return }

        switch ownership.kind {
        case .preview:
            record.previewTokens.remove(tokenID)
        case .share:
            record.shareTokens.remove(tokenID)
        }

        if ownership.kind == .share, record.shareTokens.isEmpty {
            record.session.stopSharing()
        }

        if record.previewTokens.isEmpty, record.shareTokens.isEmpty {
            record.state = .draining
            sessionsByDisplayID[ownership.displayID] = record
            let session = record.session
            sessionDrainTasksByDisplayID[ownership.displayID]?.cancel()
            sessionDrainTasksByDisplayID[ownership.displayID] = Task { [session] in
                await session.stop()
                self.finishDrainingSession(displayID: ownership.displayID)
            }
            return
        }

        record.state = .active
        sessionsByDisplayID[ownership.displayID] = record
    }

    private func waitForDrainCompletion(for displayID: CGDirectDisplayID) async {
        guard let drainTask = sessionDrainTasksByDisplayID[displayID] else { return }
        await drainTask.value
    }

    private func finishDrainingSession(displayID: CGDirectDisplayID) {
        sessionDrainTasksByDisplayID[displayID] = nil
        guard let record = sessionsByDisplayID[displayID] else { return }
        guard record.state == .draining else { return }
        guard record.previewTokens.isEmpty, record.shareTokens.isEmpty else {
            var resumed = record
            resumed.state = .active
            sessionsByDisplayID[displayID] = resumed
            return
        }
        sessionsByDisplayID.removeValue(forKey: displayID)
    }
}

// MARK: - Stream Output Delegate

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

// MARK: - Sample Fanout

private final class DisplaySampleFanout: Sendable {
    private let sinks = Mutex<[ObjectIdentifier: any DisplayPreviewSink]>([:])

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        sinks.withLock { $0[ObjectIdentifier(sink as AnyObject)] = sink }
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        sinks.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(sink as AnyObject)) }
    }

    nonisolated func publishPreviewFrame(_ sampleBuffer: CMSampleBuffer) {
        let snapshot = sinks.withLock { Array($0.values) }
        for sink in snapshot { sink.submitFrame(sampleBuffer) }
    }
}

// MARK: - Display Capture Session

final class DisplayCaptureSession: @unchecked Sendable, DisplayCaptureSessioning {
    nonisolated let displayID: CGDirectDisplayID
    nonisolated let sessionHub: WebRTCSessionHub

    nonisolated(unsafe) private let stream: SCStream
    private let output = DisplayStreamOutput()
    nonisolated private let captureQueue: DispatchQueue
    nonisolated private let fanout = DisplaySampleFanout()
    nonisolated private let metrics = Mutex(DisplayCaptureMetrics())

    // MARK: Lifecycle

    nonisolated init(display: SCDisplay) async throws {
        self.displayID = display.displayID
        self.captureQueue = DispatchQueue(
            label: "com.developerchen.voiddisplay.capture.\(display.displayID)",
            qos: .userInitiated
        )

        let config = try await Self.makeStreamConfiguration(display: display)
        let filter = try await Self.makeContentFilter(display: display)
        self.stream = SCStream(filter: filter, configuration: config, delegate: output)
        self.sessionHub = WebRTCSessionHub()

        output.session = self

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
    }

    // MARK: Preview Sinks

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.attachPreviewSink(sink)
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.detachPreviewSink(sink)
    }

    // MARK: Sharing Control

    nonisolated func stopSharing() {
        sessionHub.stopSharing()
    }

    nonisolated func stop() async {
        stopSharing()
        try? await stream.stopCapture()
    }

    // MARK: Frame Handling

    nonisolated func handle(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        metrics.withLock { $0.receivedFrameCount &+= 1 }

        fanout.publishPreviewFrame(sampleBuffer)

        guard sessionHub.hasDemand else { return }
        let ptsUs = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        sessionHub.submitFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
    }
}

// MARK: - DisplayCaptureSession Helpers

extension DisplayCaptureSession {

    nonisolated static func microseconds(from time: CMTime) -> UInt64 {
        guard time.isValid, !time.isIndefinite, time.seconds.isFinite else { return 0 }
        let scaled = CMTimeConvertScale(time, timescale: 1_000_000, method: .default)
        return scaled.value > 0 ? UInt64(scaled.value) : 0
    }

    nonisolated private static func makeStreamConfiguration(
        display: SCDisplay
    ) async throws -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let displayMode = CGDisplayCopyDisplayMode(display.displayID)

        let captureSize = preferredCaptureSize(display: display, displayMode: displayMode)
        let refreshRate = max(60.0, min(displayMode?.refreshRate ?? 60.0, 120.0))
        let timescale = CMTimeScale(max(1, Int32(refreshRate.rounded())))

        config.width = captureSize.width
        config.height = captureSize.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: timescale)
        config.queueDepth = 2
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        AppLog.capture.notice(
            "Capture config display=\(display.displayID, privacy: .public) size=\(captureSize.width)x\(captureSize.height, privacy: .public)"
        )
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

// MARK: - Internal Metrics

struct DisplayCaptureMetrics: Sendable {
    var receivedFrameCount: UInt64 = 0
}
