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
            minBitrateBps: 1_500_000,
            maxBitrateBps: 8_000_000,
            pixelBudgetPerSecond: WebRTCStreamingProfile.h264SmoothPixelBudgetPerSecond
        ))
        #expect(WebRTCStreamingProfile(performanceMode: .automatic) == WebRTCStreamingProfile(
            framesPerSecond: 30,
            minBitrateBps: 1_500_000,
            maxBitrateBps: 8_000_000,
            pixelBudgetPerSecond: WebRTCStreamingProfile.h264AutomaticPixelBudgetPerSecond
        ))
        #expect(WebRTCStreamingProfile(performanceMode: .powerEfficient) == WebRTCStreamingProfile(
            framesPerSecond: 30,
            minBitrateBps: 800_000,
            maxBitrateBps: 5_000_000,
            pixelBudgetPerSecond: WebRTCStreamingProfile.h264PowerEfficientPixelBudgetPerSecond
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

        #expect(smoothDimensions.width == 886)
        #expect(smoothDimensions.height == 498)
        #expect(automaticDimensions.width == 1_254)
        #expect(automaticDimensions.height == 704)
        #expect(powerEfficientDimensions.width == 960)
        #expect(powerEfficientDimensions.height == 540)
        #expect(wideDimensions.width == 1_454)
        #expect(wideDimensions.height == 608)
        #expect(portraitDimensions.width == 704)
        #expect(portraitDimensions.height == 1_254)
    }

    @Test func streamingProfileOutputFitsH264Level31MacroblockBudget() {
        let samples: [(WebRTCStreamingProfile, Int32, Int32)] = [
            (WebRTCStreamingProfile(performanceMode: .smooth), 3_840, 2_160),
            (WebRTCStreamingProfile(performanceMode: .automatic), 3_840, 2_160),
            (WebRTCStreamingProfile(performanceMode: .powerEfficient), 3_840, 2_160),
            (WebRTCStreamingProfile(performanceMode: .automatic), 2_428, 1_518),
            (WebRTCStreamingProfile(performanceMode: .smooth), 2_428, 1_518),
            (WebRTCStreamingProfile(performanceMode: .automatic), 2_160, 3_840),
        ]

        for (profile, width, height) in samples {
            let dimensions = profile.outputDimensions(forWidth: width, height: height)
            let macroblocks = macroblockCount(width: dimensions.width, height: dimensions.height)

            #expect(macroblocks <= 3_600)
            #expect(macroblocks * profile.framesPerSecond <= 108_000)
        }
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

    @Test func h264CodecPreferenceKeepsOnlyH264AndMatchingRtx() {
        let descriptors = [
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
        ]

        #expect(WebRTCCodecPreference.requiredH264DescriptorIndexes(from: descriptors) == [2, 3])
        #expect(WebRTCCodecPreference.requiredH264DescriptorIndexes(from: Array(descriptors.prefix(2))) == nil)
    }

    @Test func sdpVideoCodecSummaryListsVideoPayloadNames() {
        let sdp = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=rtpmap:111 opus/48000/2
        m=video 9 UDP/TLS/RTP/SAVPF 102 103
        a=rtpmap:102 H264/90000
        a=rtpmap:103 rtx/90000
        """

        #expect(WebRTCCodecPreference.sdpVideoCodecSummary(from: sdp) == "102:H264,103:rtx")
    }

    @Test func capabilitySummaryDoesNotPrintNonH264CodecNames() {
        let descriptors = [
            WebRTCCodecPreferenceDescriptor(
                name: kRTCH264CodecName,
                payloadType: 102,
                parameters: ["profile-level-id": "42e01f"]
            ),
            WebRTCCodecPreferenceDescriptor(
                name: kRTCVp8CodecName,
                payloadType: 96,
                parameters: [:]
            ),
        ]

        let summary = WebRTCCodecPreference.capabilitySummary(from: descriptors)

        #expect(summary.contains("H264"))
        #expect(summary.contains("nonH264CodecCount=1"))
        #expect(!summary.contains("VP8"))
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

private func macroblockCount(width: Int32, height: Int32) -> Int {
    let macroblockWidth = (Int(width) + 15) / 16
    let macroblockHeight = (Int(height) + 15) / 16
    return macroblockWidth * macroblockHeight
}
