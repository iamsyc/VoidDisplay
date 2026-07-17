"use strict";

const path = require("node:path");

const resourceDirectory = path.resolve(
    __dirname,
    "../../Sources/VoidDisplaySharing/Resources"
);

function loadBrowserRuntimeModules(...resourceNames) {
    globalThis.VoidDisplayBrowser = {};
    for (const resourceName of resourceNames) {
        const resourcePath = require.resolve(path.join(resourceDirectory, `${resourceName}.js`));
        delete require.cache[resourcePath];
        require(resourcePath);
    }
    return globalThis.VoidDisplayBrowser;
}

module.exports = { loadBrowserRuntimeModules };
