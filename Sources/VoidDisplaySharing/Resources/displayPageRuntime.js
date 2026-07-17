(function startDisplayPageRuntime(root) {
    "use strict";

    const runtime = root.VoidDisplayBrowser;
    const bootstrapElement = root.document.getElementById("voiddisplay-bootstrap");
    const ui = runtime.ui.createDisplayPageUI({
        documentObject: root.document,
        navigatorObject: root.navigator,
        messagesObject: messages
    });
    const bootstrap = runtime.ui.parseBootstrapJSON(bootstrapElement?.textContent);
    const connection = runtime.connection.createDisplayPageConnection({
        windowObject: root,
        signalPath: "__SIGNAL_PATH__",
        bootstrap,
        ui,
        codec: runtime.codec,
        statsAPI: runtime.stats,
        peerAPI: runtime.peer
    });

    connection.start();
})(window);
