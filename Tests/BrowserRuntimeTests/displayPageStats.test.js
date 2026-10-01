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

test("videoInboundStatsFromReport selects the H265 inbound video report", () => {
    const reports = new Map([
        ["codec-vp8", { id: "codec-vp8", type: "codec", mimeType: "video/VP8" }],
        ["inbound-vp8", {
            id: "inbound-vp8",
            type: "inbound-rtp",
            kind: "video",
            codecId: "codec-vp8"
        }],
        ["codec-h265", { id: "codec-h265", type: "codec", mimeType: "video/H265" }],
        ["inbound-h265", {
            id: "inbound-h265",
            type: "inbound-rtp",
            mediaType: "video",
            codecId: "codec-h265"
        }]
    ]);

    const selected = stats.videoInboundStatsFromReport(reports);
    assert.equal(selected.report.id, "inbound-h265");
    assert.equal(selected.codec.id, "codec-h265");
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
