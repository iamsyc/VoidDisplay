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
    @Test func h265PreservesHiDPISourcesWithinLevel6() {
        for source in [
            SourceVideoSpec(width: 3_840, height: 2_160, framesPerSecond: 60),
            SourceVideoSpec(width: 3_840, height: 2_400, framesPerSecond: 60),
            SourceVideoSpec(width: 5_120, height: 2_880, framesPerSecond: 60),
        ] {
            for mode in [CapturePerformanceMode.automatic, .smooth] {
                let profile = WebRTCStreamingProfile(performanceMode: mode, sourceVideoSpec: source)
                #expect(profile.outputVideoSpec(for: .h265) == source)
            }
        }
    }

    @Test func h265ConstrainsCodedPictureSizeAndSampleRateToLevel6() {
        for source in [
            SourceVideoSpec(width: 8_192, height: 8_192, framesPerSecond: 15),
            SourceVideoSpec(width: 8_192, height: 8_192, framesPerSecond: 60),
            SourceVideoSpec(width: 7_680, height: 4_320, framesPerSecond: 120),
            // VideoToolbox pads this to 4224 squared, which exceeds Level 6 at 60 fps.
            SourceVideoSpec(width: 4_222, height: 4_222, framesPerSecond: 60),
        ] {
            for mode in [CapturePerformanceMode.automatic, .smooth, .powerEfficient] {
                let profile = WebRTCStreamingProfile(performanceMode: mode, sourceVideoSpec: source)
                let output = profile.outputVideoSpec(for: .h265)
                let codedPixels = Int64((output.dimensions.width + 15) / 16 * 16) * Int64((output.dimensions.height + 15) / 16 * 16)
                #expect(codedPixels <= 35_651_584)
                #expect(codedPixels * Int64(output.framesPerSecond) <= 1_069_547_520)
                #expect(output.dimensions.width <= source.dimensions.width && output.dimensions.height <= source.dimensions.height)
                #expect(abs(Double(output.dimensions.width) / Double(output.dimensions.height) - Double(source.dimensions.width) / Double(source.dimensions.height)) < 0.02)
                let limits = profile.bitrateLimits(for: .h265, outputWidth: Int32(output.dimensions.width), outputHeight: Int32(output.dimensions.height))
                #expect(profile.maxBitrateBps == limits.maxBitrateBps)
                #expect(profile.maxBitrateBps <= 60_000_000)
            }
        }
    }

    @Test func automaticAndSmoothProfilesUseSourceSpecForH265() {
        let sourceSpec = SourceVideoSpec(width: 2_560, height: 1_440, framesPerSecond: 60)
        for mode in [CapturePerformanceMode.automatic, .smooth] {
            let profile = WebRTCStreamingProfile(performanceMode: mode, sourceVideoSpec: sourceSpec)
            let h265Dimensions = profile.outputDimensions(for: .h265, width: 2_560, height: 1_440)

            #expect(profile.framesPerSecond == 60)
            #expect(profile.framesPerSecond(for: .h265) == 60)
            #expect(profile.pixelBudgetPerSecond == nil)
            #expect(h265Dimensions.width == 2_560)
            #expect(h265Dimensions.height == 1_440)
            #expect(profile.outputVideoSpec(for: .h265) == sourceSpec)
        }
    }

    @Test func powerEfficientProfileKeepsOnlyActiveDowngradeBudget() {
        let sourceSpec = SourceVideoSpec(width: 2_560, height: 1_440, framesPerSecond: 60)
        let profile = WebRTCStreamingProfile(performanceMode: .powerEfficient, sourceVideoSpec: sourceSpec)
        let dimensions = profile.outputDimensions(for: .h265, width: 2_560, height: 1_440)

        #expect(profile.framesPerSecond == 30)
        #expect(profile.pixelBudgetPerSecond == SharedCapturePerformanceBudget.powerEfficientPixelBudgetPerSecond)
        #expect(dimensions.width == 1_920)
        #expect(dimensions.height == 1_080)
    }

    @Test func bitrateProfilesScaleWithH265PixelRate() {
        let profile1440p60 = WebRTCStreamingProfile(
            performanceMode: .automatic,
            sourceVideoSpec: SourceVideoSpec(width: 2_560, height: 1_440, framesPerSecond: 60)
        )
        let profile4K60 = WebRTCStreamingProfile(
            performanceMode: .automatic,
            sourceVideoSpec: SourceVideoSpec(width: 3_840, height: 2_160, framesPerSecond: 60)
        )

        let h265Limits = profile1440p60.bitrateLimits(for: .h265, outputWidth: 2_560, outputHeight: 1_440)
        let h2654KLimits = profile4K60.bitrateLimits(for: .h265, outputWidth: 3_840, outputHeight: 2_160)

        #expect(h265Limits.maxBitrateBps == 11_059_200)
        #expect(h2654KLimits.maxBitrateBps == 24_883_200)
    }

#if canImport(WebRTC)
    @Test func annexBPrefixesHEVCParameterSetsAndEveryNAL() {
        let lengthPrefixed = Data([0, 0, 0, 3, 0x26, 0x01, 0x80, 0, 0, 0, 2, 0x4E, 0x01])
        // Real VideoToolbox Main profile, High tier, Level 6 parameter sets.
        let parameterSets = [
            Data(base64Encoded: "QAEMAf//IWAAAAMAsAAAAwAAAwC0FwJA")!,
            Data(base64Encoded: "QgEBIWAAAAMAsAAAAwAAAwC0oAHgIAJYWIF7kWRS/8ufxP6I")!,
            Data(base64Encoded: "RAHAcvBTJA==")!,
        ]
        let mainTierParameters = [
            Data(base64Encoded: "QAEMAf//AWAAAAMAsAAAAwAAAwC0FwJA")!,
            Data(base64Encoded: "QgEBAWAAAAMAsAAAAwAAAwC0oAHgIAJYWIF7kWRS/8ufxP6I")!,
            parameterSets[2],
        ]
        var expected = Data()
        for parameter in mainTierParameters {
            expected.append(contentsOf: [0, 0, 0, 1])
            expected.append(parameter)
        }
        expected.append(contentsOf: [0, 0, 0, 1, 0x26, 0x01, 0x80, 0, 0, 0, 1, 0x4E, 0x01])
        #expect(HEVCAnnexB.convert(lengthPrefixed, headerLength: 4, parameterSets: parameterSets) == expected)
        #expect(HEVCAnnexB.convert(Data([0, 2, 0x02, 0x01]), headerLength: 2, parameterSets: []) == Data([0, 0, 0, 1, 0x02, 0x01]))
    }

    @Test func annexBDeclaresTheBoundedLevelAndRejectsOutOfContractParameterSets() {
        let nal = Data([0, 0, 0, 2, 0x26, 0x01])
        var parameter = Data(base64Encoded: "QAEMAf//IWAAAAMAsAAAAwAAAwC0FwJA")!
        // Level 5.1 from the same hardware path must use the shared Level 6
        // declaration, whose Main-tier bitrate limit is enforced by the encoder.
        parameter[20] = 153
        var expectedParameter = parameter
        expectedParameter[6] = 1
        expectedParameter[20] = 180
        var expected = Data([0, 0, 0, 1])
        expected.append(expectedParameter)
        expected.append(contentsOf: [0, 0, 0, 1, 0x26, 0x01])
        #expect(HEVCAnnexB.convert(nal, headerLength: 4, parameterSets: [parameter]) == expected)
        var inBand = Data([0, 0, 0, UInt8(parameter.count)])
        inBand.append(parameter)
        inBand.append(nal)
        #expect(HEVCAnnexB.convert(inBand, headerLength: 4, parameterSets: []) == expected)
        parameter[20] = 183
        #expect(HEVCAnnexB.convert(nal, headerLength: 4, parameterSets: [parameter]) == nil)
        parameter[20] = 180
        parameter[6] = 0x22
        #expect(HEVCAnnexB.convert(nal, headerLength: 4, parameterSets: [parameter]) == nil)
        parameter[6] = 0x21
        parameter[3] |= 2
        #expect(HEVCAnnexB.convert(nal, headerLength: 4, parameterSets: [parameter]) == nil)
        #expect(HEVCAnnexB.convert(nal, headerLength: 4, parameterSets: [Data([0x40, 0x01])]) == nil)
    }

    @Test func annexBRejectsTruncatedNALAndLengthFields() {
        #expect(HEVCAnnexB.convert(Data([0, 0, 0, 5, 0x65]), headerLength: 4, parameterSets: []) == nil)
        #expect(HEVCAnnexB.convert(Data([0, 0]), headerLength: 4, parameterSets: []) == nil)
        #expect(HEVCAnnexB.convert(Data([0, 0, 0, 0]), headerLength: 4, parameterSets: []) == nil)
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
                name: "H265",
                payloadType: 104,
                parameters: [:]
            ),
            WebRTCCodecPreferenceDescriptor(
                name: kRTCRtxCodecName,
                payloadType: 105,
                parameters: ["apt": "104"]
            ),
        ]

        #expect(WebRTCCodecPreference.requiredDescriptorIndexes(for: .h265, from: descriptors) == [2, 3])
        #expect(WebRTCCodecPreference.requiredDescriptorIndexes(for: .h265, from: Array(descriptors.prefix(2))) == nil)
    }

    @Test func sdpVideoCodecSummaryListsVideoPayloadNames() {
        let sdp = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=rtpmap:111 opus/48000/2
        m=video 9 UDP/TLS/RTP/SAVPF 104 105
        a=rtpmap:104 H265/90000
        a=rtpmap:105 rtx/90000
        m=video 9 UDP/TLS/RTP/SAVPF 102 103
        a=rtpmap:102 VP8/90000
        a=rtpmap:103 rtx/90000
        """

        #expect(WebRTCCodecPreference.sdpVideoCodecSummary(from: sdp) == "104:H265,105:rtx,103:rtx; unexpectedVideoCodecCount=1")

        let reusedPayloadTypeSDP = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=rtpmap:96 H265/90000
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=rtpmap:96 VP8/90000
        """

        #expect(WebRTCCodecPreference.sdpVideoCodecSummary(from: reusedPayloadTypeSDP) == "96:H265; unexpectedVideoCodecCount=1")
    }

    @Test func capabilitySummaryPrintsH265ProbeWithoutUnsupportedCodecNames() {
        let descriptors = [
            WebRTCCodecPreferenceDescriptor(
                name: "H265",
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

        #expect(summary.contains("H265=H265(pt=35,fmtp=none)"))
        #expect(summary.contains("unsupportedVideoCodecCount=1"))
        #expect(!summary.contains("VP8"))
    }

    @Test func runtimeSenderCapabilityProbePrintsCurrentWebRTCBinaryCodecs() {
        let pipeline = WebRTCMediaPipeline()
        let summary = pipeline.senderVideoCodecCapabilitySummary()

        print("VoidDisplay WebRTC sender codec capability probe: \(summary)")
        #expect(summary.contains("H265="))
        #expect(summary.contains("level-id=180"))
        #expect(summary.contains("unsupportedVideoCodecCount="))
    }

    @Test func publisherOfferRetainsHEVCMainLevel6() async throws {
        let pipeline = WebRTCMediaPipeline()
        let peer = try #require(pipeline.makePeerConnection())
        defer { peer.close() }
        let initialization = RTCRtpTransceiverInit()
        initialization.direction = .sendOnly
        let transceiver = try #require(peer.addTransceiver(with: pipeline.h265VideoTrack, init: initialization))
        let codecs = try #require(pipeline.requiredCodecs(for: .h265))
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

        #expect(description.sdp.contains("level-id=180"))
        #expect(description.sdp.contains("profile-id=1"))
        #expect(description.sdp.contains("H265/90000"))
        #expect(!description.sdp.contains("H264/90000"))
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
