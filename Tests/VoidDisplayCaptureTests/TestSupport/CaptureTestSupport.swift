@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Synchronization

final class CaptureTestSCDisplayBox: NSObject {
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

enum SharedMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = CaptureTestSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}

final class TestDisplayShareFrameConsumer: DisplayShareFrameConsumer {
    private let performanceModes = Mutex<[CapturePerformanceMode]>([])

    nonisolated init() {}

    nonisolated var hasDemand: Bool { false }

    nonisolated func updateSourceVideoSpec(_: SourceVideoSpec) {}

    nonisolated func updatePerformanceMode(_ mode: CapturePerformanceMode) {
        performanceModes.withLock { $0.append(mode) }
    }

    nonisolated func stopSharing() {}

    nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}

    var recordedPerformanceModes: [CapturePerformanceMode] {
        performanceModes.withLock { $0 }
    }
}

enum AsyncTestTimeouts {
    static let shortStabilityWindow: UInt64 = 1_500_000_000
    static let defaultAsyncAssertion: UInt64 = 3_000_000_000
}

final class TestCapturePreviewSession: @unchecked Sendable {
    private nonisolated(unsafe) let sampleBuffer: CMSampleBuffer

    init(sourcePixelSize: CGSize) throws {
        self.sampleBuffer = try Self.makeSampleBuffer(sourcePixelSize: sourcePixelSize)
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        sink.submitFrame(sampleBuffer)
    }

    private static func makeSampleBuffer(sourcePixelSize: CGSize) throws -> CMSampleBuffer {
        let width = max(1, Int(sourcePixelSize.width.rounded()))
        let height = max(1, Int(sourcePixelSize.height.rounded()))
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TestSampleBufferError.pixelBufferCreationFailed(status)
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw TestSampleBufferError.formatDescriptionCreationFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw TestSampleBufferError.sampleBufferCreationFailed(sampleStatus)
        }
        return sampleBuffer
    }
}

private enum TestSampleBufferError: Error {
    case pixelBufferCreationFailed(CVReturn)
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
}

@MainActor
func waitUntil(
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
    pollNanoseconds: UInt64 = 10_000_000,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
    }
    return condition()
}

@MainActor
func staysTrue(
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.shortStabilityWindow,
    pollNanoseconds: UInt64 = 10_000_000,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if !condition() {
            return false
        }
        try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
    }
    return condition()
}

func staysTrue(
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.shortStabilityWindow,
    pollNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if !(await condition()) {
            return false
        }
        try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
    }
    return await condition()
}

@MainActor
func drainMainActorTasks(iterations: Int = 5) async {
    for _ in 0..<max(0, iterations) {
        await Task.yield()
    }
}

@MainActor
final class MockCapturePreviewService: CapturePreviewServiceProtocol {
    var currentSessions: [ScreenPreviewSession] = []
    var addCallCount = 0
    var removeCallCount = 0
    var removeByDisplayCallCount = 0
    var removedDisplayIDs: [CGDirectDisplayID] = []
    var updateStateCallCount = 0
    var updateCapturesCursorCallCount = 0

    func previewSession(for id: UUID) -> ScreenPreviewSession? {
        currentSessions.first(where: { $0.id == id })
    }

    func addPreviewSession(_ session: ScreenPreviewSession) {
        addCallCount += 1
        currentSessions.append(session)
    }

    func updatePreviewSessionState(
        id: UUID,
        state: ScreenPreviewSession.State
    ) {
        updateStateCallCount += 1
        guard let index = currentSessions.firstIndex(where: { $0.id == id }) else { return }
        currentSessions[index].state = state
    }

    func updatePreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) {
        updateCapturesCursorCallCount += 1
        guard let index = currentSessions.firstIndex(where: { $0.id == id }) else { return }
        currentSessions[index].capturesCursor = capturesCursor
    }

    func removePreviewSession(id: UUID) {
        removeCallCount += 1
        currentSessions.removeAll { $0.id == id }
    }

    func removePreviewSessions(displayID: CGDirectDisplayID) {
        removeByDisplayCallCount += 1
        removedDisplayIDs.append(displayID)
        currentSessions.removeAll { $0.displayID == displayID }
    }
}
