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
