"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { loadBrowserRuntimeModules } = require("./runtimeTestSupport");

const { codec } = loadBrowserRuntimeModules("displayPageCodec");
const mainLevel6 = "profile-id=1;tier-flag=0;level-id=180;tx-mode=SRST";

test("receiverCodecPreferences keeps H265 and its matching RTX codec", () => {
    const h265 = { mimeType: "video/H265", payloadType: 96, sdpFmtpLine: mainLevel6 };
    const h265RTX = { mimeType: "video/rtx", payloadType: 97, sdpFmtpLine: "apt=96" };
    const vp8 = { mimeType: "video/VP8", payloadType: 102 };
    const vp8RTX = { mimeType: "video/rtx", payloadType: 103, parameters: { apt: 102 } };
    const receiver = {
        getCapabilities(kind) {
            assert.equal(kind, "video");
            return { codecs: [vp8, h265RTX, vp8RTX, h265] };
        }
    };

    assert.deepEqual(
        codec.receiverCodecPreferences(receiver, "H265 required"),
        [h265, h265RTX]
    );
});

test("H265 preferences and answers require the shared Main Level 6 contract", () => {
    for (const [fmtp, supported] of [
        [mainLevel6, true],
        ["level-id=180", true],
        [mainLevel6.replace("180", "183"), true],
        [mainLevel6.replace("180", "153"), false],
        [mainLevel6.replace("profile-id=1", "profile-id=2"), false],
        [mainLevel6.replace("tier-flag=0", "tier-flag=1"), false],
        [mainLevel6.replace("SRST", "MRST"), false],
        [mainLevel6.replace("180", "invalid"), false],
        ["", false],
    ]) {
        const h265 = { mimeType: "video/H265", payloadType: 96, sdpFmtpLine: fmtp };
        const receiver = { getCapabilities: () => ({ codecs: [h265] }) };
        const sdp = `m=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 H265/90000\r\na=fmtp:96 ${fmtp}\r\n`;
        if (supported) {
            assert.deepEqual(codec.receiverCodecPreferences(receiver, "Main Level 6 required"), [h265]);
            assert.equal(codec.selectedCodecFromAnswerSDP(sdp, "Main Level 6 required"), "h265");
        } else {
            assert.throws(() => codec.receiverCodecPreferences(receiver, "Main Level 6 required"),
                (error) => codec.isCodecRequirementError(error), fmtp);
            assert.throws(() => codec.selectedCodecFromAnswerSDP(sdp, "Main Level 6 required"),
                /Main Level 6 required/u, fmtp);
        }
    }
});

test("receiverCodecPreferences excludes weaker H265 formats and their RTX", () => {
    const supported = { mimeType: "video/H265", payloadType: 96, sdpFmtpLine: mainLevel6 };
    const weaker = { mimeType: "video/H265", payloadType: 98, sdpFmtpLine: mainLevel6.replace("180", "153") };
    const rtx = { mimeType: "video/rtx", payloadType: 97, sdpFmtpLine: "apt=96" };
    const weakerRTX = { mimeType: "video/rtx", payloadType: 99, sdpFmtpLine: "apt=98" };
    const receiver = { getCapabilities: () => ({ codecs: [weaker, weakerRTX, supported, rtx] }) };
    assert.deepEqual(codec.receiverCodecPreferences(receiver, "Main Level 6 required"), [supported, rtx]);
});

test("receiverCodecPreferences reports a codec requirement when H265 is absent", () => {
    assert.throws(
        () => codec.receiverCodecPreferences({ getCapabilities: () => ({ codecs: [] }) }, "H265 required"),
        (error) => error.message === "H265 required" && codec.isCodecRequirementError(error)
    );
});

test("videoCodecNamesFromSDP follows video payload order and ignores audio", () => {
    const sdp = [
        "v=0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=rtpmap:111 opus/48000/2",
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        "a=rtpmap:97 rtx/90000",
        "a=rtpmap:96 H265/90000",
        `a=fmtp:96 ${mainLevel6}`,
        ""
    ].join("\r\n");

    assert.deepEqual(codec.videoCodecNamesFromSDP(sdp), ["h265", "rtx"]);
    assert.equal(codec.selectedCodecFromAnswerSDP(sdp, "H265 required"), "h265");
});

test("selectedCodecFromAnswerSDP rejects an answer containing another primary codec", () => {
    const sdp = [
        "m=video 9 UDP/TLS/RTP/SAVPF 96 102",
        "a=rtpmap:96 H265/90000",
        "a=rtpmap:102 VP8/90000",
        ""
    ].join("\r\n");

    assert.throws(
        () => codec.selectedCodecFromAnswerSDP(sdp, "H265 required"),
        /H265 required/u
    );
});
