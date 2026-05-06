@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
import Synchronization
import Testing

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

private final class ScheduledOperations: @unchecked Sendable {
    private let operations = Mutex<[@Sendable () -> Void]>([])

    nonisolated func schedule(_ operation: @escaping @Sendable () -> Void) {
        operations.withLock { $0.append(operation) }
    }

    func count() -> Int {
        operations.withLock { $0.count }
    }

    @discardableResult
    func runNext() -> Bool {
        let operation = operations.withLock { operations -> (@Sendable () -> Void)? in
            guard !operations.isEmpty else { return nil }
            return operations.removeFirst()
        }
        operation?()
        return operation != nil
    }
}

private final class MailboxReference<Frame: Sendable>: @unchecked Sendable {
    nonisolated(unsafe) var mailbox: WebRTCFrameMailbox<Frame>?
}

struct WebRTCSessionSupportTests {
    @Test func streamingProfilesMatchPerformanceModes() {
        #expect(WebRTCStreamingProfile(performanceMode: .smooth) == WebRTCStreamingProfile(
            framesPerSecond: 60,
            minBitrateBps: 3_000_000,
            maxBitrateBps: 32_000_000,
            pixelBudgetPerSecond: nil
        ))
        #expect(WebRTCStreamingProfile(performanceMode: .automatic) == WebRTCStreamingProfile(
            framesPerSecond: 60,
            minBitrateBps: 2_000_000,
            maxBitrateBps: 24_000_000,
            pixelBudgetPerSecond: SharedCapturePerformanceBudget.automaticPixelBudgetPerSecond
        ))
        #expect(WebRTCStreamingProfile(performanceMode: .powerEfficient) == WebRTCStreamingProfile(
            framesPerSecond: 30,
            minBitrateBps: 1_000_000,
            maxBitrateBps: 12_000_000,
            pixelBudgetPerSecond: SharedCapturePerformanceBudget.powerEfficientPixelBudgetPerSecond
        ))
    }

    @Test func streamingProfilesApplyPixelBudgetByMode() {
        let smoothDimensions = WebRTCStreamingProfile(performanceMode: .smooth)
            .outputDimensions(forWidth: 3_840, height: 2_160)
        let automaticDimensions = WebRTCStreamingProfile(performanceMode: .automatic)
            .outputDimensions(forWidth: 3_840, height: 2_160)
        let powerEfficientDimensions = WebRTCStreamingProfile(performanceMode: .powerEfficient)
            .outputDimensions(forWidth: 3_840, height: 2_160)
        let wideDimensions = WebRTCStreamingProfile(performanceMode: .automatic)
            .outputDimensions(forWidth: 3_440, height: 1_440)
        let portraitDimensions = WebRTCStreamingProfile(performanceMode: .automatic)
            .outputDimensions(forWidth: 2_160, height: 3_840)

        #expect(smoothDimensions.width == 3_840)
        #expect(smoothDimensions.height == 2_160)
        #expect(automaticDimensions.width == 2_560)
        #expect(automaticDimensions.height == 1_440)
        #expect(powerEfficientDimensions.width == 1_920)
        #expect(powerEfficientDimensions.height == 1_080)
        #expect(wideDimensions.width == 2_968)
        #expect(wideDimensions.height == 1_242)
        #expect(portraitDimensions.width == 1_440)
        #expect(portraitDimensions.height == 2_560)
    }

#if canImport(WebRTC)
    @Test func frameTimestampSequencerPreservesIncreasingPresentationTimestamps() {
        var sequencer = WebRTCFrameTimestampSequencer()

        #expect(sequencer.nextTimestampNs(ptsUs: 1_000, framesPerSecond: 60) == 1_000_000)
        #expect(sequencer.nextTimestampNs(ptsUs: 2_000, framesPerSecond: 60) == 2_000_000)
    }

    @Test func frameTimestampSequencerRepairsRepeatedPresentationTimestamps() {
        var sequencer = WebRTCFrameTimestampSequencer()

        #expect(sequencer.nextTimestampNs(ptsUs: 0, framesPerSecond: 60) == 0)
        #expect(sequencer.nextTimestampNs(ptsUs: 0, framesPerSecond: 60) == 16_666_666)
        #expect(sequencer.nextTimestampNs(ptsUs: 0, framesPerSecond: 30) == 49_999_999)
    }

    @Test func vp8CodecPreferenceKeepsVp8AndMatchingRtx() {
        let descriptors = [
            WebRTCCodecPreferenceDescriptor(
                name: kRTCH264CodecName,
                payloadType: 102,
                parameters: [:]
            ),
            WebRTCCodecPreferenceDescriptor(
                name: kRTCRtxCodecName,
                payloadType: 103,
                parameters: ["apt": "102"]
            ),
            WebRTCCodecPreferenceDescriptor(
                name: kRTCVp8CodecName,
                payloadType: 96,
                parameters: [:]
            ),
            WebRTCCodecPreferenceDescriptor(
                name: kRTCRtxCodecName,
                payloadType: 97,
                parameters: ["apt": "96"]
            ),
        ]

        #expect(WebRTCCodecPreference.preferredVP8DescriptorIndexes(from: descriptors) == [2, 3])
        #expect(WebRTCCodecPreference.preferredVP8DescriptorIndexes(from: Array(descriptors.prefix(2))) == nil)
    }
#endif

    @Test func frameMailboxKeepsOnlyLatestPendingFrameBeforeDrainStarts() {
        let scheduler = ScheduledOperations()
        let consumed = Mutex<[Int]>([])
        let mailbox = WebRTCFrameMailbox<Int>(
            scheduler: { operation in scheduler.schedule(operation) },
            consumer: { frame in consumed.withLock { $0.append(frame) } }
        )

        mailbox.submit(1)
        mailbox.submit(2)
        mailbox.submit(3)

        #expect(scheduler.count() == 1)
        #expect(consumed.withLock { $0 } == [])
        #expect(scheduler.runNext())
        #expect(consumed.withLock { $0 } == [3])
    }

    @Test func frameMailboxCoalescesFramesSubmittedWhileDraining() {
        let scheduler = ScheduledOperations()
        let consumed = Mutex<[Int]>([])
        let mailboxReference = MailboxReference<Int>()
        let mailbox = WebRTCFrameMailbox<Int>(
            scheduler: { operation in scheduler.schedule(operation) },
            consumer: { frame in
                consumed.withLock { $0.append(frame) }
                if frame == 1 {
                    mailboxReference.mailbox?.submit(2)
                    mailboxReference.mailbox?.submit(3)
                }
            }
        )
        mailboxReference.mailbox = mailbox

        mailbox.submit(1)

        #expect(scheduler.runNext())
        #expect(consumed.withLock { $0 } == [1, 3])
        #expect(scheduler.count() == 0)
    }
}
