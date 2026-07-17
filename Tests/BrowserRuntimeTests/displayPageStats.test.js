"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { loadBrowserRuntimeModules } = require("./runtimeTestSupport");

const { stats } = loadBrowserRuntimeModules("displayPageStats");

test("sourceSpecFromSignal validates and normalizes the source dimensions", () => {
    assert.deepEqual(
        stats.sourceSpecFromSignal({ width: 1919.6, height: "1080", framesPerSecond: 59.7 }),
        { width: 1920, height: 1080, framesPerSecond: 60 }
    );
    assert.equal(stats.sourceSpecFromSignal({ width: 1920, height: 0, framesPerSecond: 60 }), null);
});

test("videoInboundStatsFromReport selects the AV1 inbound video report", () => {
    const reports = new Map([
        ["codec-h264", { id: "codec-h264", type: "codec", mimeType: "video/H264" }],
        ["inbound-h264", {
            id: "inbound-h264",
            type: "inbound-rtp",
            kind: "video",
            codecId: "codec-h264"
        }],
        ["codec-av1", { id: "codec-av1", type: "codec", mimeType: "video/AV1" }],
        ["inbound-av1", {
            id: "inbound-av1",
            type: "inbound-rtp",
            mediaType: "video",
            codecId: "codec-av1"
        }]
    ]);

    const selected = stats.videoInboundStatsFromReport(reports);
    assert.equal(selected.report.id, "inbound-av1");
    assert.equal(selected.codec.id, "codec-av1");
});

test("deriveBrowserStatsSample computes bitrate and decoded frame rate", () => {
    const first = stats.deriveBrowserStatsSample(
        { lastBytesReceived: null, lastFramesDecoded: null, lastTimestamp: null },
        { timestamp: 1000, bytesReceived: 1000, framesDecoded: 10 },
        1000
    );
    assert.equal(first.derived, null);

    const second = stats.deriveBrowserStatsSample(
        first.nextState,
        { timestamp: 3000, bytesReceived: 251000, framesDecoded: 70 },
        3000
    );
    assert.deepEqual(second.derived, {
        bitrateBps: 1_000_000,
        framesPerSecond: 30
    });
});

test("classifyLiveStats separates degraded transport from low-motion content", () => {
    const sourceSpec = { width: 1920, height: 1080, framesPerSecond: 60 };
    assert.equal(
        stats.classifyLiveStats(
            1280,
            720,
            30,
            { packetsLost: 0, framesDropped: 0 },
            { bitrateBps: 200_000 },
            sourceSpec
        ),
        "degraded"
    );
    assert.equal(
        stats.classifyLiveStats(
            1920,
            1080,
            5,
            { packetsLost: 0, framesDropped: 0 },
            { bitrateBps: 200_000 },
            sourceSpec
        ),
        "lowMotion"
    );
    assert.equal(
        stats.classifyLiveStats(
            1920,
            1080,
            60,
            { packetsLost: 0, framesDropped: 0 },
            { bitrateBps: 8_000_000 },
            sourceSpec
        ),
        "normal"
    );
});
