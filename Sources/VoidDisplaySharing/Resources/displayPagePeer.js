(function registerDisplayPagePeer(root) {
    "use strict";

    const namespace = root.VoidDisplayBrowser || {};
    root.VoidDisplayBrowser = namespace;

    function createDisplayPagePeer({
        windowObject,
        bootstrap,
        ui,
        codec,
        statsAPI,
        getConnectionState,
        transitionConnection,
        sendSignal,
        schedulePeerRetry,
        onStreamingStarted,
        onConnectionLost,
        onCodecRequirementFailure
    }) {
        const firstVideoFrameTimeoutMs = 10000;
        const localOfferIceTimeoutMs = 2000;
        let peer = null;
        let peerLifecycleID = 0;
        let expectedSourceVideoSpec = null;

        const browserStatsMonitor = statsAPI.createBrowserStatsMonitor({
            windowObject,
            performanceObject: windowObject.performance,
            player: ui.player,
            getPeer: () => peer,
            getSourceSpec: () => expectedSourceVideoSpec,
            getState: getConnectionState,
            setVideoInfo: ui.setVideoInfo,
            t: ui.t
        });

        function close() {
            peerLifecycleID += 1;
            browserStatsMonitor.stop();
            if (peer) {
                peer.ontrack = null;
                peer.onicecandidate = null;
                peer.onconnectionstatechange = null;
                peer.close();
                peer = null;
            }
            ui.player.srcObject = null;
            ui.setVideoInfo("");
        }

        function localOfferSDPWithIceCredentials() {
            const localDescription = peer?.localDescription;
            if (
                !localDescription ||
                localDescription.type !== "offer" ||
                typeof localDescription.sdp !== "string" ||
                localDescription.sdp.length === 0
            ) {
                return null;
            }
            if (!/(^|\r?\n)a=ice-ufrag:/u.test(localDescription.sdp)) {
                return null;
            }
            return localDescription.sdp;
        }

        async function waitForLocalOfferSDP() {
            const startedAt = windowObject.performance.now();
            while (windowObject.performance.now() - startedAt < localOfferIceTimeoutMs) {
                const sdp = localOfferSDPWithIceCredentials();
                if (sdp) {
                    return sdp;
                }
                await new Promise((resolve) => windowObject.setTimeout(resolve, 25));
            }
            throw new Error("Local WebRTC offer is missing ICE credentials.");
        }

        function streamStartupTimeoutError() {
            const error = new Error(ui.t("overlayFirstFrameTimeoutBody"));
            error.streamStartupTimeout = true;
            return error;
        }

        function isStreamStartupTimeoutError(error) {
            return Boolean(error?.streamStartupTimeout);
        }

        function hasCurrentVideoFrame() {
            return Number(ui.player.readyState || 0) >= 2;
        }

        function waitForFirstVideoFrame(timeoutMs = firstVideoFrameTimeoutMs) {
            if (hasCurrentVideoFrame()) {
                return Promise.resolve();
            }
            return new Promise((resolve, reject) => {
                let resolved = false;
                let timeoutID = null;
                const cleanup = () => {
                    if (timeoutID !== null) {
                        windowObject.clearTimeout(timeoutID);
                        timeoutID = null;
                    }
                    if (typeof ui.player.removeEventListener === "function") {
                        ui.player.removeEventListener("loadeddata", finishIfReady);
                        ui.player.removeEventListener("canplay", finishIfReady);
                        ui.player.removeEventListener("playing", finishIfReady);
                    }
                };
                const settle = (callback) => {
                    if (resolved) return;
                    resolved = true;
                    cleanup();
                    callback();
                };
                const finishIfReady = () => {
                    if (!hasCurrentVideoFrame()) return;
                    settle(resolve);
                };
                timeoutID = windowObject.setTimeout(() => {
                    settle(() => reject(streamStartupTimeoutError()));
                }, timeoutMs);
                if (typeof ui.player.requestVideoFrameCallback === "function") {
                    ui.player.requestVideoFrameCallback(() => settle(resolve));
                    return;
                }
                ui.player.addEventListener("loadeddata", finishIfReady);
                ui.player.addEventListener("canplay", finishIfReady);
                ui.player.addEventListener("playing", finishIfReady);
            });
        }

        async function start() {
            close();
            const lifecycleID = ++peerLifecycleID;
            peer = new windowObject.RTCPeerConnection({ iceServers: bootstrap.iceServers ?? [] });
            const activePeer = peer;
            if (typeof activePeer.addTransceiver !== "function") {
                throw codec.codecRequirementError(ui.t("overlayCodecRequiredBody"));
            }
            const codecPreferences = codec.receiverCodecPreferences(
                windowObject.RTCRtpReceiver,
                ui.t("overlayCodecRequiredBody")
            );
            const transceiver = activePeer.addTransceiver("video", { direction: "recvonly" });
            if (typeof transceiver.setCodecPreferences !== "function") {
                throw codec.codecRequirementError(ui.t("overlayCodecRequiredBody"));
            }
            try {
                transceiver.setCodecPreferences(codecPreferences);
            } catch (error) {
                throw codec.codecRequirementError(error?.message || ui.t("overlayCodecRequiredBody"));
            }

            activePeer.ontrack = async (event) => {
                if (event.streams && event.streams[0]) {
                    const stream = event.streams[0];
                    ui.player.srcObject = stream;
                    try {
                        await waitForFirstVideoFrame();
                        if (peer !== activePeer || lifecycleID !== peerLifecycleID || ui.player.srcObject !== stream) {
                            return;
                        }
                        ui.setConnectionStatus(ui.t("statusLive"), ui.t("overlayLiveBody"));
                        ui.setLoadingOverlayVisible(false);
                        onStreamingStarted();
                        transitionConnection("streaming");
                        browserStatsMonitor.start(activePeer);
                    } catch (error) {
                        if (isStreamStartupTimeoutError(error)) {
                            console.warn("[VoidDisplay] First video frame timed out", error);
                            close();
                            schedulePeerRetry(
                                ui.t("overlayFirstFrameTimeoutTitle"),
                                error.message || ui.t("overlayFirstFrameTimeoutBody")
                            );
                            return;
                        }
                        onCodecRequirementFailure(error);
                    }
                }
            };

            activePeer.onicecandidate = (event) => {
                if (!event.candidate) {
                    sendSignal({ type: "ice_complete" });
                    return;
                }
                sendSignal({
                    type: "ice_candidate",
                    candidate: event.candidate.candidate,
                    sdpMid: event.candidate.sdpMid,
                    sdpMLineIndex: event.candidate.sdpMLineIndex
                });
            };

            activePeer.onconnectionstatechange = () => {
                if (
                    activePeer.connectionState === "failed" ||
                    activePeer.connectionState === "disconnected"
                ) {
                    onConnectionLost();
                }
            };

            const offer = await activePeer.createOffer();
            await activePeer.setLocalDescription(offer);
            await sendSignal({ type: "offer", sdp: await waitForLocalOfferSDP() });
            transitionConnection("negotiating");
        }

        async function applyAnswer(payload) {
            if (!peer || typeof payload.sdp !== "string") return false;
            codec.selectedCodecFromAnswerSDP(
                payload.sdp,
                ui.t("overlayCodecAnswerRequiredBody")
            );
            expectedSourceVideoSpec = statsAPI.sourceSpecFromSignal(payload.sourceVideoSpec);
            await peer.setRemoteDescription({
                type: "answer",
                sdp: payload.sdp
            });
            return true;
        }

        async function addIceCandidate(payload) {
            if (!peer || typeof payload.candidate !== "string") return false;
            await peer.addIceCandidate({
                candidate: payload.candidate,
                sdpMid: payload.sdpMid || null,
                sdpMLineIndex: Number.isInteger(payload.sdpMLineIndex) ? payload.sdpMLineIndex : 0
            });
            return true;
        }

        return Object.freeze({
            addIceCandidate,
            applyAnswer,
            close,
            start
        });
    }

    namespace.peer = Object.freeze({ createDisplayPagePeer });
})(globalThis);
