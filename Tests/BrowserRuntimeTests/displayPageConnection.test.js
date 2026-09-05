"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { loadBrowserRuntimeModules } = require("./runtimeTestSupport");

const { connection } = loadBrowserRuntimeModules("displayPageConnection");

test("reconnectDelayAt caps exponential retry delays at the final value", () => {
    const delays = [250, 500, 1000, 2000, 4000];
    assert.equal(connection.reconnectDelayAt(delays, 0), 250);
    assert.equal(connection.reconnectDelayAt(delays, 3), 2000);
    assert.equal(connection.reconnectDelayAt(delays, 20), 4000);
});

test("connection start reports a missing WebSocket without starting a peer", () => {
    const statusUpdates = [];
    const overlayVisibility = [];
    let peerStartCount = 0;
    let beforeUnloadHandler = null;
    const controller = connection.createDisplayPageConnection({
        windowObject: {
            WebSocket: undefined,
            RTCPeerConnection: function RTCPeerConnection() {},
            addEventListener(eventName, handler) {
                assert.equal(eventName, "beforeunload");
                beforeUnloadHandler = handler;
            }
        },
        signalPath: "/signal/5",
        bootstrap: { iceServers: [] },
        ui: {
            t: (key) => key,
            setConnectionStatus: (...args) => statusUpdates.push(args),
            setLoadingOverlayVisible: (visible) => overlayVisibility.push(visible)
        },
        codec: {},
        statsAPI: {},
        peerAPI: {
            createDisplayPagePeer: () => ({
                addIceCandidate: async () => false,
                applyAnswer: async () => false,
                close() {},
                async start() {
                    peerStartCount += 1;
                }
            })
        }
    });

    controller.start();

    assert.equal(typeof beforeUnloadHandler, "function");
    assert.equal(peerStartCount, 0);
    assert.deepEqual(statusUpdates, [["overlayWebSocketRequiredTitle", "overlayWebSocketRequiredBody"]]);
    assert.deepEqual(overlayVisibility, [false]);
});

function makeConnectionHarness({ fetchPage = async () => ({ status: 200 }), startPeer = async () => {}, applyAnswer = async () => true } = {}) {
    const sockets = [];
    const timers = new Map();
    const requests = [];
    const statusUpdates = [];
    let nextTimerID = 1;
    let peerOptions;
    let overlayVisible = false;
    class FakeSocket {
        static CONNECTING = 0;
        static OPEN = 1;
        constructor(url) {
            this.url = url;
            this.readyState = FakeSocket.CONNECTING;
            this.listeners = {};
            sockets.push(this);
        }
        addEventListener(name, handler) { this.listeners[name] = handler; }
        send() {}
        emit(name, payload) {
            if (name === "open") this.readyState = FakeSocket.OPEN;
            if (name === "close") this.readyState = 3;
            return this.listeners[name]?.(payload);
        }
        close() { return this.emit("close"); }
    }
    const controller = connection.createDisplayPageConnection({
        windowObject: {
            WebSocket: FakeSocket,
            RTCPeerConnection() {},
            AbortSignal,
            location: { protocol: "http:", host: "localhost:8089", pathname: "/display/5/capability" },
            addEventListener() {},
            setTimeout(callback) { const id = nextTimerID++; timers.set(id, callback); return id; },
            clearTimeout(id) { timers.delete(id); },
            async fetch(path, options) { requests.push({ path, options }); return fetchPage(); }
        },
        signalPath: "/signal/5/capability",
        bootstrap: { iceServers: [] },
        ui: {
            t: (key) => key,
            setConnectionStatus: (...args) => statusUpdates.push(args),
            setLoadingOverlayVisible: (visible) => { overlayVisible = visible; },
            setProgressOverlay: (...args) => { statusUpdates.push(args); overlayVisible = true; }
        },
        codec: { isCodecRequirementError: () => false },
        statsAPI: {},
        peerAPI: {
            createDisplayPagePeer(options) {
                peerOptions = options;
                return { close() {}, start: startPeer, applyAnswer, addIceCandidate: async () => true };
            }
        }
    });
    return {
        controller, sockets, timers, requests, statusUpdates,
        getPeerOptions: () => peerOptions,
        overlayVisible: () => overlayVisible,
        async runTimer() {
            assert.equal(timers.size, 1);
            const [id, callback] = timers.entries().next().value;
            timers.delete(id);
            await callback();
        }
    };
}

test("a revoked sharing page stops reconnecting after the socket closes", async () => {
    const harness = makeConnectionHarness({ fetchPage: async () => ({ status: 404 }) });
    harness.controller.start();
    harness.sockets[0].emit("close");
    await harness.runTimer();

    assert.equal(harness.requests.length, 1);
    assert.equal(harness.requests[0].path, "/display/5/capability");
    assert.equal(harness.requests[0].options.cache, "no-store");
    assert.equal(harness.sockets.length, 1);
    assert.equal(harness.timers.size, 0);
    assert.deepEqual(harness.statusUpdates.at(-1), ["overlaySharingStoppedTitle", "overlaySharingStoppedBody"]);
    assert.equal(harness.overlayVisible(), false);
});

test("a live sharing page reconnects after a transient socket loss", async () => {
    const harness = makeConnectionHarness();
    harness.controller.start();
    harness.sockets[0].emit("close");
    await harness.runTimer();

    assert.equal(harness.requests.length, 1);
    assert.equal(harness.sockets.length, 2);
    await harness.sockets[1].emit("open");
    assert.equal(harness.timers.size, 0);
    assert.deepEqual(harness.statusUpdates.at(-1), ["overlayNegotiatingTitle", "overlayNegotiatingBody"]);
    harness.controller.stop();
});

test("network and server failures keep retrying until the sharing page responds", async () => {
    let attempt = 0;
    const harness = makeConnectionHarness({ fetchPage: async () => {
        attempt += 1;
        if (attempt === 1) throw new TypeError("Network unavailable");
        return { status: attempt === 2 ? 503 : 200 };
    } });
    harness.controller.start();
    harness.sockets[0].emit("close");
    await harness.runTimer();
    assert.equal(harness.sockets.length, 1);
    await harness.runTimer();
    assert.equal(harness.sockets.length, 1);
    await harness.runTimer();
    assert.equal(harness.requests.length, 3);
    assert.equal(harness.sockets.length, 2);
    harness.controller.stop();
});

test("explicit sharing stop is terminal for late peer callbacks", async () => {
    let finishPeerStart;
    const harness = makeConnectionHarness({ startPeer: () => new Promise((_, reject) => { finishPeerStart = reject; }) });
    harness.controller.start();
    const opening = harness.sockets[0].emit("open");
    await Promise.resolve();
    await harness.sockets[0].emit("message", { data: JSON.stringify({ type: "stopped" }) });
    finishPeerStart(new Error("Peer closed"));
    await opening;
    harness.getPeerOptions().onConnectionLost();
    harness.getPeerOptions().transitionConnection("negotiating");

    assert.deepEqual(harness.statusUpdates.at(-1), ["overlaySharingStoppedTitle", "overlaySharingStoppedBody"]);
    assert.equal(harness.timers.size, 0);
    assert.equal(harness.overlayVisible(), false);
    assert.equal(harness.getPeerOptions().getConnectionState(), "closed");
});

test("sharing stop remains visible when an in-flight peer retry completes", async () => {
    let starts = 0;
    let finishRetry;
    const harness = makeConnectionHarness({ startPeer: async () => {
        if (++starts === 1) return;
        await new Promise((resolve) => { finishRetry = resolve; });
    } });
    harness.controller.start();
    await harness.sockets[0].emit("open");
    harness.getPeerOptions().schedulePeerRetry("retry", "retry");
    const retrying = harness.runTimer();
    await harness.sockets[0].emit("message", { data: JSON.stringify({ type: "stopped" }) });
    finishRetry();
    await retrying;
    assert.deepEqual(harness.statusUpdates.at(-1), ["overlaySharingStoppedTitle", "overlaySharingStoppedBody"]);
    assert.equal(harness.overlayVisible(), false);
});

test("an answer completing after sharing stops cannot restore connected status", async () => {
    let finishAnswer;
    const harness = makeConnectionHarness({ applyAnswer: () => new Promise((resolve) => { finishAnswer = resolve; }) });
    harness.controller.start();
    const answering = harness.sockets[0].emit("message", { data: JSON.stringify({ type: "answer", sdp: "answer" }) });
    await harness.sockets[0].emit("message", { data: JSON.stringify({ type: "stopped" }) });
    finishAnswer(true);
    await answering;
    assert.deepEqual(harness.statusUpdates.at(-1), ["overlaySharingStoppedTitle", "overlaySharingStoppedBody"]);
});

test("stopping during a sharing-page check prevents a late reconnection", async () => {
    let finishFetch;
    const harness = makeConnectionHarness({ fetchPage: () => new Promise((resolve) => { finishFetch = resolve; }) });
    harness.controller.start();
    harness.sockets[0].emit("close");
    const checking = harness.runTimer();
    harness.controller.stop();
    assert.equal(typeof finishFetch, "function");
    finishFetch({ status: 200 });
    await checking;

    assert.equal(harness.sockets.length, 1);
    assert.equal(harness.timers.size, 0);
});
