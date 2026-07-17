(function registerDisplayPageConnection(root) {
    "use strict";

    const namespace = root.VoidDisplayBrowser || {};
    root.VoidDisplayBrowser = namespace;

    function reconnectDelayAt(delays, reconnectIndex) {
        return delays[Math.min(reconnectIndex, delays.length - 1)];
    }

    function createDisplayPageConnection({
        windowObject,
        signalPath,
        bootstrap,
        ui,
        codec,
        statsAPI,
        peerAPI
    }) {
        const reconnectDelays = [250, 500, 1000, 2000, 4000];
        let socket = null;
        let reconnectIndex = 0;
        let reconnectTimer = null;
        let terminalStop = false;
        let state = "idle";

        function transition(nextState) {
            state = nextState;
        }

        function isSocketConnectingOrOpen(webSocket) {
            if (!webSocket) return false;
            return webSocket.readyState === windowObject.WebSocket.CONNECTING ||
                webSocket.readyState === windowObject.WebSocket.OPEN;
        }

        function closeSocketAndClearReference() {
            const webSocket = socket;
            if (!webSocket) return;
            socket = null;
            try {
                webSocket.close();
            } catch {
                // Closing an already-failed socket has no remaining work.
            }
        }

        function clearReconnectTimer() {
            if (reconnectTimer) {
                windowObject.clearTimeout(reconnectTimer);
                reconnectTimer = null;
            }
        }

        function scheduleReconnect(
            overlayTitle = ui.t("overlayReconnectTitle"),
            overlayBody = ui.t("overlayReconnectBody")
        ) {
            if (terminalStop || state === "stopping" || state === "closed") {
                return;
            }
            if (reconnectTimer) {
                return;
            }
            const delay = reconnectDelayAt(reconnectDelays, reconnectIndex);
            reconnectIndex += 1;
            ui.setProgressOverlay(overlayTitle, overlayBody);
            transition("handshaking");
            reconnectTimer = windowObject.setTimeout(() => {
                reconnectTimer = null;
                connect();
            }, delay);
        }

        function schedulePeerRetry(overlayTitle, overlayBody) {
            if (terminalStop || state === "stopping" || state === "closed") {
                return;
            }
            if (reconnectTimer) {
                return;
            }
            const delay = reconnectDelayAt(reconnectDelays, reconnectIndex);
            reconnectIndex += 1;
            ui.setProgressOverlay(overlayTitle, overlayBody);
            transition("signalingReady");
            reconnectTimer = windowObject.setTimeout(async () => {
                reconnectTimer = null;
                if (terminalStop || state === "stopping" || state === "closed") {
                    return;
                }
                if (!socket || socket.readyState !== windowObject.WebSocket.OPEN) {
                    scheduleReconnect(overlayTitle, overlayBody);
                    return;
                }
                try {
                    await peerController.start();
                    ui.setProgressOverlay(ui.t("overlayNegotiatingTitle"), ui.t("overlayNegotiatingBody"));
                } catch (error) {
                    handlePeerStartupError(error);
                }
            }, delay);
        }

        async function sendSignal(payload) {
            if (!socket || socket.readyState !== windowObject.WebSocket.OPEN) return;
            socket.send(JSON.stringify(payload));
        }

        function failCodecRequirement(error) {
            terminalStop = true;
            ui.setConnectionStatus(
                ui.t("overlayCodecRequiredTitle"),
                error?.message || ui.t("overlayCodecRequiredBody")
            );
            ui.setLoadingOverlayVisible(false);
            clearReconnectTimer();
            peerController.close();
            closeSocketAndClearReference();
            transition("closed");
        }

        function handlePeerStartupError(error) {
            if (codec.isCodecRequirementError(error)) {
                failCodecRequirement(error);
                return;
            }
            ui.setProgressOverlay(
                ui.t("overlayNegotiationFailedTitle"),
                error?.message || ui.t("overlayNegotiationFailedFallback")
            );
            closeSocketAndClearReference();
            scheduleReconnect();
        }

        function handlePeerConnectionLost() {
            ui.setProgressOverlay(ui.t("overlayConnectionLostTitle"), ui.t("overlayConnectionLostBody"));
            if (!terminalStop) {
                closeSocketAndClearReference();
                scheduleReconnect();
            }
        }

        function isCodecErrorReason(reason) {
            return reason === "unsupported_video_codec_offered" || reason === "supported_video_codec_missing";
        }

        const peerController = peerAPI.createDisplayPagePeer({
            windowObject,
            bootstrap,
            ui,
            codec,
            statsAPI,
            getConnectionState: () => state,
            transitionConnection: transition,
            sendSignal,
            schedulePeerRetry,
            onStreamingStarted: () => {
                reconnectIndex = 0;
            },
            onConnectionLost: handlePeerConnectionLost,
            onCodecRequirementFailure: failCodecRequirement
        });

        function connect() {
            if (terminalStop || state === "closed") return;
            if (isSocketConnectingOrOpen(socket)) return;
            if (!windowObject.WebSocket) {
                ui.setConnectionStatus(ui.t("overlayWebSocketRequiredTitle"), ui.t("overlayWebSocketRequiredBody"));
                ui.setLoadingOverlayVisible(false);
                transition("closed");
                return;
            }
            if (!windowObject.RTCPeerConnection) {
                ui.setConnectionStatus(ui.t("overlayWebRTCRequiredTitle"), ui.t("overlayWebRTCRequiredBody"));
                ui.setLoadingOverlayVisible(false);
                transition("closed");
                return;
            }

            const protocol = windowObject.location.protocol === "https:" ? "wss" : "ws";
            const webSocketURL = `${protocol}://${windowObject.location.host}${signalPath}`;
            const webSocket = new windowObject.WebSocket(webSocketURL);
            socket = webSocket;
            transition("handshaking");
            ui.setProgressOverlay(ui.t("overlayConnectingTitle"), ui.t("overlayConnectingBody"));

            webSocket.addEventListener("open", async () => {
                if (socket !== webSocket) return;
                reconnectIndex = 0;
                clearReconnectTimer();
                transition("signalingReady");
                ui.setConnectionStatus(ui.t("statusSignalingConnected"), ui.t("overlayConnectingBody"));
                await sendSignal({ type: "viewer_ready" });
                try {
                    await peerController.start();
                    ui.setProgressOverlay(ui.t("overlayNegotiatingTitle"), ui.t("overlayNegotiatingBody"));
                } catch (error) {
                    handlePeerStartupError(error);
                }
            });

            webSocket.addEventListener("message", async (event) => {
                if (socket !== webSocket || typeof event.data !== "string") return;

                let payload;
                try {
                    payload = JSON.parse(event.data);
                } catch {
                    return;
                }
                if (!payload || typeof payload.type !== "string") return;

                switch (payload.type) {
                    case "answer":
                        try {
                            if (await peerController.applyAnswer(payload)) {
                                ui.setConnectionStatus(ui.t("statusConnected"), ui.t("overlayLiveBody"));
                            }
                        } catch (error) {
                            failCodecRequirement(error);
                        }
                        break;
                    case "ice_candidate":
                        await peerController.addIceCandidate(payload);
                        break;
                    case "stopped":
                        terminalStop = true;
                        transition("stopping");
                        ui.setConnectionStatus(ui.t("overlaySharingStoppedTitle"), ui.t("overlaySharingStoppedBody"));
                        ui.setLoadingOverlayVisible(false);
                        peerController.close();
                        clearReconnectTimer();
                        closeSocketAndClearReference();
                        transition("closed");
                        break;
                    case "codec_pending":
                        ui.setProgressOverlay(ui.t("overlayCodecPendingTitle"), ui.t("overlayCodecPendingBody"));
                        peerController.close();
                        schedulePeerRetry(ui.t("overlayCodecPendingTitle"), ui.t("overlayCodecPendingBody"));
                        break;
                    case "error":
                        if (isCodecErrorReason(payload.reason)) {
                            failCodecRequirement(new Error(ui.t("overlayCodecAnswerRequiredBody")));
                            break;
                        }
                        terminalStop = true;
                        ui.setConnectionStatus(
                            ui.t("overlayStreamErrorTitle"),
                            payload.reason || ui.t("overlayStreamErrorFallback")
                        );
                        ui.setLoadingOverlayVisible(false);
                        clearReconnectTimer();
                        peerController.close();
                        closeSocketAndClearReference();
                        transition("closed");
                        break;
                    default:
                        break;
                }
            });

            webSocket.addEventListener("close", () => {
                if (socket !== webSocket) return;
                socket = null;
                peerController.close();
                if (terminalStop || state === "closed" || state === "stopping") {
                    ui.setConnectionStatus(ui.t("statusStopped"));
                    transition("closed");
                    return;
                }
                scheduleReconnect();
            });

            webSocket.addEventListener("error", () => {
                if (socket !== webSocket) return;
                ui.setConnectionStatus(ui.t("statusConnectionError"));
            });
        }

        function stop() {
            terminalStop = true;
            clearReconnectTimer();
            peerController.close();
            closeSocketAndClearReference();
        }

        function start() {
            windowObject.addEventListener("beforeunload", stop);
            connect();
        }

        return Object.freeze({ start, stop });
    }

    namespace.connection = Object.freeze({
        createDisplayPageConnection,
        reconnectDelayAt
    });
})(globalThis);
