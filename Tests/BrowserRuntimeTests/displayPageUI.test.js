"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { loadBrowserRuntimeModules } = require("./runtimeTestSupport");

const { ui } = loadBrowserRuntimeModules("displayPageUI");

test("resolveLocale chooses Simplified Chinese for supported Chinese preferences", () => {
    assert.equal(ui.resolveLocale({ languages: ["fr-FR", "zh-CN"] }), "zhHans");
    assert.equal(ui.resolveLocale({ language: "zh-Hant" }), "zhHans");
});

test("resolveLocale falls back to English", () => {
    assert.equal(ui.resolveLocale({ languages: ["fr-FR", "ja-JP"] }), "en");
    assert.equal(ui.resolveLocale(undefined), "en");
});

test("parseBootstrapJSON accepts only an iceServers array", () => {
    const valid = ui.parseBootstrapJSON('{"iceServers":[{"urls":["stun:localhost"]}]}');
    assert.deepEqual(valid, {
        iceServers: [{ urls: ["stun:localhost"] }]
    });
    assert.deepEqual(ui.parseBootstrapJSON('{"iceServers":"stun:localhost"}'), { iceServers: [] });
    assert.deepEqual(ui.parseBootstrapJSON("not-json"), { iceServers: [] });
    assert.deepEqual(ui.parseBootstrapJSON(""), { iceServers: [] });
});
