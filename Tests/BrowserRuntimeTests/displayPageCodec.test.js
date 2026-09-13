"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { loadBrowserRuntimeModules } = require("./runtimeTestSupport");

const { codec } = loadBrowserRuntimeModules("displayPageCodec");

test("receiverCodecPreferences keeps H264 and its matching RTX codec", () => {
    const h264 = { mimeType: "video/H264", payloadType: 96 };
    const h264RTX = { mimeType: "video/rtx", payloadType: 97, sdpFmtpLine: "apt=96" };
    const vp8 = { mimeType: "video/VP8", payloadType: 102 };
    const vp8RTX = { mimeType: "video/rtx", payloadType: 103, parameters: { apt: 102 } };
    const receiver = {
        getCapabilities(kind) {
            assert.equal(kind, "video");
            return { codecs: [vp8, h264RTX, vp8RTX, h264] };
        }
    };

    assert.deepEqual(
        codec.receiverCodecPreferences(receiver, "H264 required"),
        [h264, h264RTX]
    );
});

test("receiverCodecPreferences reports a codec requirement when H264 is absent", () => {
    assert.throws(
        () => codec.receiverCodecPreferences({ getCapabilities: () => ({ codecs: [] }) }, "H264 required"),
        (error) => error.message === "H264 required" && codec.isCodecRequirementError(error)
    );
});

test("videoCodecNamesFromSDP follows video payload order and ignores audio", () => {
    const sdp = [
        "v=0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=rtpmap:111 opus/48000/2",
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        "a=rtpmap:97 rtx/90000",
        "a=rtpmap:96 H264/90000",
        ""
    ].join("\r\n");

    assert.deepEqual(codec.videoCodecNamesFromSDP(sdp), ["h264", "rtx"]);
    assert.equal(codec.selectedCodecFromAnswerSDP(sdp, "H264 required"), "h264");
});

test("selectedCodecFromAnswerSDP rejects an answer containing another primary codec", () => {
    const sdp = [
        "m=video 9 UDP/TLS/RTP/SAVPF 96 102",
        "a=rtpmap:96 H264/90000",
        "a=rtpmap:102 VP8/90000",
        ""
    ].join("\r\n");

    assert.throws(
        () => codec.selectedCodecFromAnswerSDP(sdp, "H264 required"),
        /H264 required/u
    );
});
