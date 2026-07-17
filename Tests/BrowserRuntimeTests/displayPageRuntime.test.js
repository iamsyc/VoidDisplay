"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

test("runtime composes the six modules and starts the connection", () => {
    let connectionStarted = false;
    const bootstrapElement = { textContent: '{"iceServers":[]}' };
    const windowObject = {
        document: {
            getElementById: (id) => id === "voiddisplay-bootstrap" ? bootstrapElement : null
        },
        navigator: {},
        VoidDisplayBrowser: {
            ui: {
                createDisplayPageUI: () => ({ marker: "ui" }),
                parseBootstrapJSON: () => ({ iceServers: [] })
            },
            codec: { marker: "codec" },
            stats: { marker: "stats" },
            peer: { marker: "peer" },
            connection: {
                createDisplayPageConnection: (dependencies) => {
                    assert.equal(dependencies.signalPath, "__SIGNAL_PATH__");
                    assert.equal(dependencies.peerAPI.marker, "peer");
                    return { start: () => { connectionStarted = true; } };
                }
            }
        }
    };
    const context = vm.createContext({
        messages: {},
        window: windowObject
    });
    const runtimePath = path.resolve(
        __dirname,
        "../../Sources/VoidDisplaySharing/Resources/displayPageRuntime.js"
    );

    vm.runInContext(fs.readFileSync(runtimePath, "utf8"), context, {
        filename: runtimePath
    });

    assert.equal(connectionStarted, true);
});
