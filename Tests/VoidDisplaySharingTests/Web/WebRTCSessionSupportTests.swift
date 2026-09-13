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
    @Test func automaticAndSmoothProfilesUseSourceSpecForH264() {
        let sourceSpec = SourceVideoSpec(width: 2_560, height: 1_440, framesPerSecond: 60)
        for mode in [CapturePerformanceMode.automatic, .smooth] {
            let profile = WebRTCStreamingProfile(performanceMode: mode, sourceVideoSpec: sourceSpec)
            let h264Dimensions = profile.outputDimensions(for: .h264, width: 2_560, height: 1_440)

            #expect(profile.framesPerSecond == 60)
            #expect(profile.framesPerSecond(for: .h264) == 60)
            #expect(profile.pixelBudgetPerSecond == nil)
            #expect(h264Dimensions.width == 2_560)
            #expect(h264Dimensions.height == 1_440)
            #expect(profile.outputVideoSpec(for: .h264) == sourceSpec)
        }
    }

    @Test func powerEfficientProfileKeepsOnlyActiveDowngradeBudget() {
        let sourceSpec = SourceVideoSpec(width: 2_560, height: 1_440, framesPerSecond: 60)
        let profile = WebRTCStreamingProfile(performanceMode: .powerEfficient, sourceVideoSpec: sourceSpec)
        let dimensions = profile.outputDimensions(for: .h264, width: 2_560, height: 1_440)

        #expect(profile.framesPerSecond == 30)
        #expect(profile.pixelBudgetPerSecond == SharedCapturePerformanceBudget.powerEfficientPixelBudgetPerSecond)
        #expect(dimensions.width == 1_920)
        #expect(dimensions.height == 1_080)
    }

    @Test func bitrateProfilesScaleWithH264PixelRate() {
        let profile1440p60 = WebRTCStreamingProfile(
            performanceMode: .automatic,
            sourceVideoSpec: SourceVideoSpec(width: 2_560, height: 1_440, framesPerSecond: 60)
        )
        let profile4K60 = WebRTCStreamingProfile(
            performanceMode: .automatic,
            sourceVideoSpec: SourceVideoSpec(width: 3_840, height: 2_160, framesPerSecond: 60)
        )

        let h264Limits = profile1440p60.bitrateLimits(for: .h264, outputWidth: 2_560, outputHeight: 1_440)
        let h2644KLimits = profile4K60.bitrateLimits(for: .h264, outputWidth: 3_840, outputHeight: 2_160)

        #expect(h264Limits.maxBitrateBps == 22_118_400)
        #expect(h2644KLimits.maxBitrateBps == 49_766_400)
    }

#if canImport(WebRTC)
    @Test func h264AnnexBPrefixesKeyframeParameterSetsAndEveryNAL() {
        let avcc = Data([0, 0, 0, 2, 0x65, 0x80, 0, 0, 0, 1, 0x06])
        let expected = Data([0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 0x80, 0, 0, 0, 1, 0x06])
        #expect(H264AnnexB.convert(avcc, headerLength: 4, parameterSets: [Data([0x67]), Data([0x68])]) == expected)
        #expect(H264AnnexB.convert(Data([0, 2, 0x41, 0x80]), headerLength: 2, parameterSets: []) == Data([0, 0, 0, 1, 0x41, 0x80]))
    }

    @Test func h264AnnexBRejectsTruncatedNALAndLengthFields() {
        #expect(H264AnnexB.convert(Data([0, 0, 0, 5, 0x65]), headerLength: 4, parameterSets: []) == nil)
        #expect(H264AnnexB.convert(Data([0, 0]), headerLength: 4, parameterSets: []) == nil)
        #expect(H264AnnexB.convert(Data([0, 0, 0, 0]), headerLength: 4, parameterSets: []) == nil)
    }

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

    @Test func codecPreferenceKeepsOnlyRequestedCodecAndMatchingRtx() {
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
                name: "H264",
                payloadType: 104,
                parameters: [:]
            ),
            WebRTCCodecPreferenceDescriptor(
                name: kRTCRtxCodecName,
                payloadType: 105,
                parameters: ["apt": "104"]
            ),
        ]

        #expect(WebRTCCodecPreference.requiredDescriptorIndexes(for: .h264, from: descriptors) == [2, 3])
        #expect(WebRTCCodecPreference.requiredDescriptorIndexes(for: .h264, from: Array(descriptors.prefix(2))) == nil)
    }

    @Test func sdpVideoCodecSummaryListsVideoPayloadNames() {
        let sdp = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=rtpmap:111 opus/48000/2
        m=video 9 UDP/TLS/RTP/SAVPF 104 105
        a=rtpmap:104 H264/90000
        a=rtpmap:105 rtx/90000
        m=video 9 UDP/TLS/RTP/SAVPF 102 103
        a=rtpmap:102 VP8/90000
        a=rtpmap:103 rtx/90000
        """

        #expect(WebRTCCodecPreference.sdpVideoCodecSummary(from: sdp) == "104:H264,105:rtx,103:rtx; unexpectedVideoCodecCount=1")

        let reusedPayloadTypeSDP = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=rtpmap:96 H264/90000
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=rtpmap:96 VP8/90000
        """

        #expect(WebRTCCodecPreference.sdpVideoCodecSummary(from: reusedPayloadTypeSDP) == "96:H264; unexpectedVideoCodecCount=1")
    }

    @Test func capabilitySummaryPrintsH264ProbeWithoutUnsupportedCodecNames() {
        let descriptors = [
            WebRTCCodecPreferenceDescriptor(
                name: "H264",
                payloadType: 35,
                parameters: [:]
            ),
            WebRTCCodecPreferenceDescriptor(
                name: kRTCVp8CodecName,
                payloadType: 96,
                parameters: [:]
            ),
        ]

        let summary = WebRTCCodecPreference.capabilitySummary(from: descriptors)

        #expect(summary.contains("H264=H264(pt=35,fmtp=none)"))
        #expect(summary.contains("unsupportedVideoCodecCount=1"))
        #expect(!summary.contains("VP8"))
    }

    @Test func runtimeSenderCapabilityProbePrintsCurrentWebRTCBinaryCodecs() {
        let pipeline = WebRTCMediaPipeline()
        let summary = pipeline.senderVideoCodecCapabilitySummary()

        print("VoidDisplay WebRTC sender codec capability probe: \(summary)")
        #expect(summary.contains("H264="))
        #expect(summary.contains("profile-level-id=640034"))
        #expect(summary.contains("unsupportedVideoCodecCount="))
    }

    @Test func publisherOfferRetainsH264Level52() async throws {
        let pipeline = WebRTCMediaPipeline()
        let peer = try #require(pipeline.makePeerConnection())
        defer { peer.close() }
        let initialization = RTCRtpTransceiverInit()
        initialization.direction = .sendOnly
        let transceiver = try #require(peer.addTransceiver(with: pipeline.h264VideoTrack, init: initialization))
        let codecs = try #require(pipeline.requiredCodecs(for: .h264))
        try transceiver.setCodecPreferences(codecs, error: ())
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                }
            }
        }

        #expect(description.sdp.contains("profile-level-id=640034"))
        #expect(!description.sdp.contains("profile-level-id=42e01f"))
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
