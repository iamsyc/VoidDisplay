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
        framesPerSecond: 30,
        packetsLost: null, framesDropped: null, presentationDrops: null,
        decodeMs: null, receiveToDecodeMs: null, jitterBufferMs: null
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
            { bitrateBps: 200_000, packetsLost: 0, framesDropped: 0 },
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
            { bitrateBps: 200_000, packetsLost: 0, framesDropped: 0 },
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

test("interval diagnostics separate packet loss, decoding, buffering and presentation", () => {
    const first = { id: "video", ssrc: 1, timestamp: 1000, bytesReceived: 100, framesDecoded: 10,
        packetsLost: 4, framesDropped: 2, totalDecodeTime: 0.02, totalProcessingDelay: 0.08,
        jitterBufferDelay: 0.05, jitterBufferEmittedCount: 10 };
    const a = stats.deriveBrowserStatsSample(null, first, 0, { droppedVideoFrames: 3 });
    const b = stats.deriveBrowserStatsSample(a.nextState, { ...first, timestamp: 2000,
        bytesReceived: 1100, framesDecoded: 20, packetsLost: 5, framesDropped: 4,
        totalDecodeTime: 0.05, totalProcessingDelay: 0.18,
        jitterBufferDelay: 0.09, jitterBufferEmittedCount: 20 }, 0, { droppedVideoFrames: 4 });
    assert.equal(b.derived.packetsLost, 1);
    assert.equal(b.derived.framesDropped, 2);
    assert.equal(b.derived.presentationDrops, 1);
    assert.ok(Math.abs(b.derived.decodeMs - 3) < 1e-9);
    assert.ok(Math.abs(b.derived.receiveToDecodeMs - 10) < 1e-9);
    assert.ok(Math.abs(b.derived.jitterBufferMs - 4) < 1e-9);
    assert.equal(b.derived.bitrateBps, 8000);
});

test("historical loss does not permanently classify a recovered stream as degraded", () => {
    const report = { timestamp: 1000, bytesReceived: 1000, framesDecoded: 60, packetsLost: 5, framesDropped: 2 };
    const a = stats.deriveBrowserStatsSample(null, report, 0);
    const next = { ...report, timestamp: 2000, bytesReceived: 2000, framesDecoded: 65 };
    const b = stats.deriveBrowserStatsSample(a.nextState, next, 0);
    assert.equal(stats.classifyLiveStats(1920, 1080, 5, next, b.derived,
        { width: 1920, height: 1080, framesPerSecond: 60 }), "lowMotion");
});

test("report replacement, counter reset and duplicate timestamps establish a fresh baseline", () => {
    const report = { id: "a", ssrc: 1, timestamp: 1000, bytesReceived: 1000, framesDecoded: 10 };
    const a = stats.deriveBrowserStatsSample(null, report, 0);
    for (const change of [{ id: "b" }, { ssrc: 2 }, { bytesReceived: 1 }, { framesDecoded: 1 }, { timestamp: 1000 }]) {
        assert.equal(stats.deriveBrowserStatsSample(a.nextState, { ...report, timestamp: 2000, ...change }, 0).derived, null);
    }
    const b = stats.deriveBrowserStatsSample(a.nextState, { ...report, timestamp: 2000 }, 0);
    assert.equal(b.derived.framesPerSecond, 0);
    assert.equal(b.derived.decodeMs, null);
    assert.equal(b.derived.packetsLost, null);
});

test("late packet recovery stays signed and missing counters are never reported as zero", () => {
    const a = stats.deriveBrowserStatsSample(null, { timestamp: 0, packetsLost: 3 }, 99);
    assert.equal(a.nextState.timestamp, 0);
    const b = stats.deriveBrowserStatsSample(a.nextState, { timestamp: 1000, packetsLost: 1, totalDecodeTime: NaN }, 0);
    assert.equal(b.derived.packetsLost, -2);
    assert.equal(b.derived.bitrateBps, null);
    assert.equal(b.derived.framesDropped, null);
    assert.equal(b.derived.decodeMs, null);
});

test("RTT follows the selected transport pair and stays separate from frame latency", () => {
    const reports = new Map([
        ["transport", { selectedCandidatePairId: "selected" }],
        ["unselected", { currentRoundTripTime: 9 }],
        ["selected", { currentRoundTripTime: 0.007 }]
    ]);
    assert.equal(stats.selectedRoundTripTimeMs(reports, { transportId: "transport" }), 7);
    assert.equal(stats.selectedRoundTripTimeMs(reports, {}), null);
});

test("monitor serializes polls and ignores completion after stop", async () => {
    let resolve;
    let tick;
    let calls = 0;
    const peer = { getStats: () => { calls += 1; return new Promise((done) => { resolve = done; }); } };
    const monitor = stats.createBrowserStatsMonitor({
        windowObject: { setInterval: (callback) => { tick = callback; return 1; }, clearInterval() {} },
        performanceObject: { now: () => 1 }, player: {}, getPeer: () => peer,
        getSourceSpec: () => null, getState: () => "streaming", setVideoInfo() {}, t: () => ""
    });
    monitor.start(peer);
    tick();
    assert.equal(calls, 1);
    monitor.stop();
    resolve(new Map());
    await Promise.resolve();
    assert.equal(stats.getLatestDiagnostics(), null);
});

test("live FPS uses a complete local interval instead of a startup burst", async () => {
    let tick;
    let report = { id: "video", ssrc: 1, type: "inbound-rtp", kind: "video", codecId: "codec",
        timestamp: 1000, frameWidth: 1920, frameHeight: 1080, framesDecoded: 10, framesPerSecond: 667 };
    const peer = { getStats: async () => new Map([
        ["codec", { id: "codec", type: "codec", mimeType: "video/H265" }],
        ["video", report]
    ]) };
    const updates = [];
    const monitor = stats.createBrowserStatsMonitor({
        windowObject: { setInterval: (callback) => { tick = callback; return 1; }, clearInterval() {} },
        performanceObject: { now: () => 1 }, player: {}, getPeer: () => peer,
        getSourceSpec: () => ({ width: 1920, height: 1080, framesPerSecond: 60 }),
        getState: () => "streaming", setVideoInfo: (value) => updates.push(value),
        t: (key, ...values) => ({ key, values })
    });
    const settle = () => new Promise((resolve) => setImmediate(resolve));
    try {
        monitor.start(peer);
        await settle();
        assert.equal(updates.at(-1).values[3], "—");
        report = { ...report, timestamp: 3000, framesDecoded: 70, framesPerSecond: 90 };
        tick(); await settle();
        assert.equal(updates.at(-1).values[3], 30);
        assert.equal(stats.getLatestDiagnostics().interval.framesPerSecond, 30);
        report = { ...report, timestamp: 5000, framesPerSecond: 30 };
        tick(); await settle();
        assert.equal(updates.at(-1).values[3], 0);
        report = { ...report, ssrc: 2, timestamp: 7000, framesDecoded: 3, framesPerSecond: 900 };
        tick(); await settle();
        assert.equal(updates.at(-1).values[3], "—");
    } finally {
        monitor.stop();
    }
});
