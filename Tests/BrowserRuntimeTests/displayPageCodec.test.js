"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { loadBrowserRuntimeModules } = require("./runtimeTestSupport");

const { codec } = loadBrowserRuntimeModules("displayPageCodec");

test("receiverCodecPreferences keeps AV1 and its matching RTX codec", () => {
    const av1 = { mimeType: "video/AV1", payloadType: 96 };
    const av1RTX = { mimeType: "video/rtx", payloadType: 97, sdpFmtpLine: "apt=96" };
    const h264 = { mimeType: "video/H264", payloadType: 102 };
    const h264RTX = { mimeType: "video/rtx", payloadType: 103, parameters: { apt: 102 } };
    const receiver = {
        getCapabilities(kind) {
            assert.equal(kind, "video");
            return { codecs: [h264, av1RTX, h264RTX, av1] };
        }
    };

    assert.deepEqual(
        codec.receiverCodecPreferences(receiver, "AV1 required"),
        [av1, av1RTX]
    );
});

test("receiverCodecPreferences reports a codec requirement when AV1 is absent", () => {
    assert.throws(
        () => codec.receiverCodecPreferences({ getCapabilities: () => ({ codecs: [] }) }, "AV1 required"),
        (error) => error.message === "AV1 required" && codec.isCodecRequirementError(error)
    );
});

test("videoCodecNamesFromSDP follows video payload order and ignores audio", () => {
    const sdp = [
        "v=0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=rtpmap:111 opus/48000/2",
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        "a=rtpmap:97 rtx/90000",
        "a=rtpmap:96 AV1/90000",
        ""
    ].join("\r\n");

    assert.deepEqual(codec.videoCodecNamesFromSDP(sdp), ["av1", "rtx"]);
    assert.equal(codec.selectedCodecFromAnswerSDP(sdp, "AV1 required"), "av1");
});

test("selectedCodecFromAnswerSDP rejects an answer containing another primary codec", () => {
    const sdp = [
        "m=video 9 UDP/TLS/RTP/SAVPF 96 102",
        "a=rtpmap:96 AV1/90000",
        "a=rtpmap:102 H264/90000",
        ""
    ].join("\r\n");

    assert.throws(
        () => codec.selectedCodecFromAnswerSDP(sdp, "AV1 required"),
        /AV1 required/u
    );
});
