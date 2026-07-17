"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { loadBrowserRuntimeModules } = require("./runtimeTestSupport");

function makeHarness({ includeCodecPreferenceAPI = true } = {}) {
    const signals = [];
    const transitions = [];
    const codecPreferences = [{ mimeType: "video/AV1", payloadType: 96 }];
    const selectedAnswers = [];
    const monitors = [];
    let peerInstance;
    let videoFrameCallback;

    class FakePeerConnection {
        constructor(configuration) {
            this.configuration = configuration;
            this.connectionState = "new";
            this.localDescription = null;
            this.remoteDescription = null;
            this.codecPreferences = null;
            peerInstance = this;
        }

        addTransceiver(kind, options) {
            this.transceiver = { kind, options };
            if (!includeCodecPreferenceAPI) return {};
            return {
                setCodecPreferences: (preferences) => {
                    this.codecPreferences = preferences;
                }
            };
        }

        async createOffer() {
            return {
                type: "offer",
                sdp: "v=0\r\na=ice-ufrag:test\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
            };
        }

        async setLocalDescription(description) {
            this.localDescription = description;
        }

        async setRemoteDescription(description) {
            this.remoteDescription = description;
        }

        async addIceCandidate(candidate) {
            this.lastIceCandidate = candidate;
        }

        close() {
            this.closed = true;
        }
    }

    const player = {
        readyState: 0,
        srcObject: null,
        addEventListener() {},
        removeEventListener() {},
        requestVideoFrameCallback(callback) {
            videoFrameCallback = callback;
        }
    };
    const ui = {
        player,
        setConnectionStatus() {},
        setLoadingOverlayVisible() {},
        setVideoInfo() {},
        t: (key) => key
    };
    const codec = {
        codecRequirementError: (message) => Object.assign(new Error(message), { codecRequirement: true }),
        receiverCodecPreferences: () => codecPreferences,
        selectedCodecFromAnswerSDP: (sdp) => {
            selectedAnswers.push(sdp);
            return "av1";
        }
    };
    const statsAPI = {
        createBrowserStatsMonitor: () => {
            const monitor = {
                startedWith: null,
                stopped: false,
                start(activePeer) { this.startedWith = activePeer; },
                stop() { this.stopped = true; }
            };
            monitors.push(monitor);
            return monitor;
        },
        sourceSpecFromSignal: (value) => value ?? null
    };
    const windowObject = {
        RTCPeerConnection: FakePeerConnection,
        RTCRtpReceiver: {},
        performance: { now: () => 0 },
        setTimeout,
        clearTimeout
    };
    const { peer } = loadBrowserRuntimeModules("displayPagePeer");
    let streamingStartedCount = 0;
    const controller = peer.createDisplayPagePeer({
        windowObject,
        bootstrap: { iceServers: [{ urls: ["stun:localhost"] }] },
        ui,
        codec,
        statsAPI,
        getConnectionState: () => "negotiating",
        transitionConnection: (state) => transitions.push(state),
        sendSignal: async (signal) => { signals.push(signal); },
        schedulePeerRetry() {},
        onStreamingStarted: () => { streamingStartedCount += 1; },
        onConnectionLost() {},
        onCodecRequirementFailure() {}
    });

    return {
        codecPreferences,
        controller,
        getPeer: () => peerInstance,
        getStreamingStartedCount: () => streamingStartedCount,
        getVideoFrameCallback: () => videoFrameCallback,
        monitors,
        player,
        selectedAnswers,
        signals,
        transitions
    };
}

test("peer start applies AV1 preferences and sends an ICE-complete offer", async () => {
    const harness = makeHarness();

    await harness.controller.start();

    const activePeer = harness.getPeer();
    assert.deepEqual(activePeer.configuration, {
        iceServers: [{ urls: ["stun:localhost"] }]
    });
    assert.deepEqual(activePeer.codecPreferences, harness.codecPreferences);
    assert.equal(harness.signals.length, 1);
    assert.equal(harness.signals[0].type, "offer");
    assert.match(harness.signals[0].sdp, /a=ice-ufrag:test/u);
    assert.deepEqual(harness.transitions, ["negotiating"]);
});

test("peer start rejects browsers without codec preference support", async () => {
    const harness = makeHarness({ includeCodecPreferenceAPI: false });

    await assert.rejects(
        harness.controller.start(),
        (error) => error.codecRequirement === true
    );
});

test("applyAnswer validates AV1 and installs the remote description", async () => {
    const harness = makeHarness();
    await harness.controller.start();
    const answerSDP = "m=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 AV1/90000\r\n";

    const applied = await harness.controller.applyAnswer({
        sdp: answerSDP,
        sourceVideoSpec: { width: 1920, height: 1080, framesPerSecond: 60 }
    });

    assert.equal(applied, true);
    assert.deepEqual(harness.selectedAnswers, [answerSDP]);
    assert.deepEqual(harness.getPeer().remoteDescription, {
        type: "answer",
        sdp: answerSDP
    });
});

test("close prevents an old track callback from entering streaming state", async () => {
    const harness = makeHarness();
    await harness.controller.start();
    const activePeer = harness.getPeer();
    const trackHandler = activePeer.ontrack;
    const stream = { id: "stream-1" };

    const trackTask = trackHandler({ streams: [stream] });
    harness.controller.close();
    harness.player.readyState = 2;
    harness.getVideoFrameCallback()();
    await trackTask;

    assert.equal(activePeer.closed, true);
    assert.equal(harness.player.srcObject, null);
    assert.equal(harness.getStreamingStartedCount(), 0);
    assert.deepEqual(harness.transitions, ["negotiating"]);
    assert.equal(harness.monitors[0].startedWith, null);
});
