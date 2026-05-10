const signalPath = "__SIGNAL_PATH__";
const bootstrapEl = document.getElementById("voiddisplay-bootstrap");
const videoInfoEl = document.getElementById("video-info");
const connectionStatusTitleEl = document.getElementById("connection-status-title");
const connectionStatusDetailEl = document.getElementById("connection-status-detail");
const overlayEl = document.getElementById("overlay");
const heroEyebrowEl = document.getElementById("hero-eyebrow");
const footnoteEl = document.getElementById("footnote");
const player = document.getElementById("player");
const stage = document.querySelector(".stage");
const scaleModeBtn = document.getElementById("scale-mode-btn");
const fullscreenBtn = document.getElementById("fullscreen-btn");

let socket = null;
let peer = null;
let reconnectIndex = 0;
let reconnectTimer = null;
var terminalStop = false;
var state = "idle";
let originalScaleEnabled = false;
let peerLifecycleID = 0;
let expectedSourceVideoSpec = null;
const browserStatsStatusIntervalMs = 2000;
const browserStatsState = {
    timer: null,
    lastBytesReceived: null,
    lastFramesDecoded: null,
    lastTimestamp: null
};
const reconnectDelays = [250, 500, 1000, 2000, 4000];
const firstVideoFrameTimeoutMs = 10000;

function resolveLocale() {
    const preferredLocales = Array.isArray(navigator.languages) && navigator.languages.length > 0
        ? navigator.languages
        : [navigator.language || "en"];
    for (const locale of preferredLocales) {
        const normalized = String(locale || "").toLowerCase();
        if (
            normalized === "zh-hans" ||
            normalized === "zh-cn" ||
            normalized === "zh-sg" ||
            normalized.startsWith("zh")
        ) {
            return "zhHans";
        }
    }
    return "en";
}

const locale = resolveLocale();
const currentMessages = messages[locale] || messages.en;

function t(key, ...args) {
    const value = currentMessages[key];
    if (typeof value === "function") {
        return value(...args);
    }
    return value ?? messages.en[key] ?? "";
}

const bootstrap = (() => {
    if (!bootstrapEl?.textContent) {
        return { iceServers: [] };
    }
    try {
        const parsed = JSON.parse(bootstrapEl.textContent);
        const iceServers = Array.isArray(parsed?.iceServers) ? parsed.iceServers : [];
        return { iceServers };
    } catch {
        return { iceServers: [] };
    }
})();
const localOfferIceTimeoutMs = 2000;

function applyStaticCopy() {
    document.title = t("pageTitle");
    if (heroEyebrowEl) {
        heroEyebrowEl.textContent = t("heroEyebrow");
    }
    if (footnoteEl) {
        footnoteEl.textContent = t("footnote");
    }
}

function setVideoInfo(text) {
    if (!videoInfoEl) return;
    const normalized = String(text || "");
    videoInfoEl.textContent = normalized;
}

function setConnectionStatus(title, detail = "") {
    if (connectionStatusTitleEl) {
        connectionStatusTitleEl.textContent = title;
    }
    if (connectionStatusDetailEl) {
        connectionStatusDetailEl.textContent = detail;
        connectionStatusDetailEl.hidden = String(detail || "").length === 0;
    }
}

function transition(nextState) {
    state = nextState;
}

function setLoadingOverlayVisible(visible) {
    overlayEl.hidden = !visible;
}

function setProgressOverlay(title, body) {
    setConnectionStatus(title, body);
    setLoadingOverlayVisible(true);
}

function applyScaleMode() {
    document.body.classList.toggle("mode-native", originalScaleEnabled);
    if (scaleModeBtn) {
        scaleModeBtn.textContent = originalScaleEnabled ? t("scaleFit") : t("scaleOriginal");
    }
}

function syncFullscreenButtonLabel() {
    if (!fullscreenBtn) return;
    fullscreenBtn.textContent = document.fullscreenElement ? t("fullscreenExit") : t("fullscreenEnter");
}

async function toggleFullscreen() {
    if (!document.fullscreenEnabled || !stage) return;
    try {
        if (document.fullscreenElement) {
            await document.exitFullscreen();
        } else {
            await stage.requestFullscreen();
        }
    } catch {
        // no-op: button state will remain unchanged
    }
}

scaleModeBtn?.addEventListener("click", () => {
    originalScaleEnabled = !originalScaleEnabled;
    applyScaleMode();
});

fullscreenBtn?.addEventListener("click", () => {
    toggleFullscreen();
});

document.addEventListener("fullscreenchange", syncFullscreenButtonLabel);
applyStaticCopy();
applyScaleMode();
syncFullscreenButtonLabel();

function closePeer() {
    peerLifecycleID += 1;
    stopBrowserStatsLoop();
    if (peer) {
        peer.ontrack = null;
        peer.onicecandidate = null;
        peer.onconnectionstatechange = null;
        peer.close();
        peer = null;
    }
    player.srcObject = null;
    setVideoInfo("");
}

function isSocketConnectingOrOpen(ws) {
    if (!ws) return false;
    return ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN;
}

function closeSocketAndClearReference() {
    const ws = socket;
    if (!ws) return;
    socket = null;
    try {
        ws.close();
    } catch {
        // no-op
    }
}

function clearReconnectTimer() {
    if (reconnectTimer) {
        window.clearTimeout(reconnectTimer);
        reconnectTimer = null;
    }
}

function scheduleReconnect(overlayTitle = t("overlayReconnectTitle"), overlayBody = t("overlayReconnectBody")) {
    if (terminalStop || state === "stopping" || state === "closed") {
        return;
    }
    if (reconnectTimer) {
        return;
    }
    const delay = reconnectDelays[Math.min(reconnectIndex, reconnectDelays.length - 1)];
    reconnectIndex += 1;
    setProgressOverlay(overlayTitle, overlayBody);
    transition("handshaking");
    reconnectTimer = window.setTimeout(() => {
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
    const delay = reconnectDelays[Math.min(reconnectIndex, reconnectDelays.length - 1)];
    reconnectIndex += 1;
    setProgressOverlay(overlayTitle, overlayBody);
    transition("signalingReady");
    reconnectTimer = window.setTimeout(async () => {
        reconnectTimer = null;
        if (terminalStop || state === "stopping" || state === "closed") {
            return;
        }
        if (!socket || socket.readyState !== WebSocket.OPEN) {
            scheduleReconnect(overlayTitle, overlayBody);
            return;
        }
        try {
            await startPeerConnection();
            setProgressOverlay(t("overlayNegotiatingTitle"), t("overlayNegotiatingBody"));
        } catch (error) {
            if (isCodecRequirementError(error)) {
                failCodecRequirement(error);
                return;
            }
            setProgressOverlay(
                t("overlayNegotiationFailedTitle"),
                error?.message || t("overlayNegotiationFailedFallback")
            );
            closeSocketAndClearReference();
            scheduleReconnect();
        }
    }, delay);
}

async function sendSignal(payload) {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify(payload));
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
    const startedAt = performance.now();
    while (performance.now() - startedAt < localOfferIceTimeoutMs) {
        const sdp = localOfferSDPWithIceCredentials();
        if (sdp) {
            return sdp;
        }
        await new Promise((resolve) => window.setTimeout(resolve, 25));
    }
    throw new Error("Local WebRTC offer is missing ICE credentials.");
}

function normalizedVideoCodecName(codec) {
    return String(codec?.mimeType || "").toLowerCase();
}

function isAV1Codec(codec) {
    return normalizedVideoCodecName(codec) === "video/av1";
}

function isRetransmissionCodec(codec) {
    return normalizedVideoCodecName(codec) === "video/rtx";
}

function codecPayloadType(codec) {
    const value = Number(codec?.payloadType ?? codec?.preferredPayloadType ?? NaN);
    return Number.isFinite(value) && value >= 0 ? Math.round(value) : null;
}

function rtxAptPayloadType(codec) {
    const parameterApt = Number(codec?.parameters?.apt ?? NaN);
    if (Number.isFinite(parameterApt) && parameterApt >= 0) {
        return Math.round(parameterApt);
    }
    const fmtpLine = String(codec?.sdpFmtpLine || "");
    const match = /(?:^|;)\s*apt=(\d+)\s*(?:;|$)/u.exec(fmtpLine);
    return match ? Number(match[1]) : null;
}

function rtxCodecsForPrimaryCodecs(allCodecs, primaryCodecs) {
    const payloadTypes = new Set(primaryCodecs
        .map(codecPayloadType)
        .filter((payloadType) => payloadType !== null));
    if (payloadTypes.size === 0) {
        return [];
    }
    return allCodecs.filter((codec) => {
        if (!isRetransmissionCodec(codec)) return false;
        const apt = rtxAptPayloadType(codec);
        return apt !== null && payloadTypes.has(apt);
    });
}

function codecRequirementError(message) {
    const error = new Error(message);
    error.codecRequirement = true;
    return error;
}

function isCodecRequirementError(error) {
    return Boolean(error?.codecRequirement);
}

function receiverCodecPreferences() {
    if (!window.RTCRtpReceiver || typeof RTCRtpReceiver.getCapabilities !== "function") {
        throw codecRequirementError(t("overlayCodecRequiredBody"));
    }
    const capabilities = RTCRtpReceiver.getCapabilities("video");
    const allCodecs = Array.isArray(capabilities?.codecs) ? capabilities.codecs : [];
    const av1Codecs = allCodecs.filter(isAV1Codec);
    if (av1Codecs.length === 0) {
        throw codecRequirementError(t("overlayCodecRequiredBody"));
    }
    return av1Codecs.concat(rtxCodecsForPrimaryCodecs(allCodecs, av1Codecs));
}

function videoCodecNamesFromSDP(sdp) {
    const lines = String(sdp || "").split(/\r?\n/u);
    let payloadTypes = [];
    let namesByPayloadType = new Map();
    let inVideo = false;
    const codecNames = [];

    function flushVideoMedia() {
        if (!inVideo) return;
        for (const payloadType of payloadTypes) {
            const codecName = namesByPayloadType.get(payloadType);
            if (codecName) {
                codecNames.push(codecName);
            }
        }
    }

    for (const line of lines) {
        if (line.startsWith("m=")) {
            flushVideoMedia();
            inVideo = line.startsWith("m=video ");
            payloadTypes = [];
            namesByPayloadType = new Map();
            if (inVideo) {
                const parts = line.trim().split(/\s+/u);
                payloadTypes.push(...parts.slice(3));
            }
            continue;
        }
        if (!inVideo || !line.startsWith("a=rtpmap:")) continue;
        const match = /^a=rtpmap:(\d+)\s+([^/\s]+)/iu.exec(line);
        if (match) {
            namesByPayloadType.set(match[1], match[2].toLowerCase());
        }
    }
    flushVideoMedia();

    return codecNames;
}

function selectedCodecFromAnswerSDP(sdp) {
    const codecNames = videoCodecNamesFromSDP(sdp);
    const primaryCodecs = codecNames.filter((name) => name !== "rtx");
    const supportedPrimaryCodecs = [...new Set(primaryCodecs.filter((name) => name === "av1"))];
    const hasUnexpectedVideoCodec = primaryCodecs.some((name) => name !== "av1");
    if (supportedPrimaryCodecs.length !== 1 || hasUnexpectedVideoCodec) {
        throw new Error(t("overlayCodecAnswerRequiredBody"));
    }
    return supportedPrimaryCodecs[0];
}

function browserStatsCodecName(codec) {
    const mimeType = String(codec?.mimeType || "").toLowerCase();
    if (mimeType === "video/av1") return "AV1";
    return mimeType || "unknown";
}

function sourceSpecFromSignal(value) {
    const width = Number(value?.width || 0);
    const height = Number(value?.height || 0);
    const framesPerSecond = Number(value?.framesPerSecond || 0);
    if (width <= 0 || height <= 0 || framesPerSecond <= 0) {
        return null;
    }
    return {
        width: Math.round(width),
        height: Math.round(height),
        framesPerSecond: Math.round(framesPerSecond)
    };
}

function resetBrowserStatsState() {
    browserStatsState.lastBytesReceived = null;
    browserStatsState.lastFramesDecoded = null;
    browserStatsState.lastTimestamp = null;
}

function stopBrowserStatsLoop() {
    if (browserStatsState.timer) {
        window.clearInterval(browserStatsState.timer);
        browserStatsState.timer = null;
    }
    resetBrowserStatsState();
}

function videoInboundStatsFromReport(stats) {
    const reports = new Map();
    stats.forEach((report) => reports.set(report.id, report));
    for (const report of reports.values()) {
        const reportKind = report.kind || report.mediaType;
        if (
            report.type !== "inbound-rtp" ||
            reportKind !== "video" ||
            !report.codecId
        ) {
            continue;
        }
        const codec = reports.get(report.codecId);
        if (!codec?.mimeType) continue;
        const mimeType = String(codec.mimeType).toLowerCase();
        if (mimeType !== "video/av1") continue;
        return { report, codec };
    }
    return null;
}

function classifyLiveStats(width, height, fps, report, derived, sourceSpec) {
    if (!sourceSpec) return "normal";
    const roundedFps = Math.max(0, Math.round(fps));
    const sourceFps = Number(sourceSpec.framesPerSecond || 0);
    const packetsLost = Number(report.packetsLost || 0);
    const framesDropped = Number(report.framesDropped || 0);
    const bitrateBps = Number(derived?.bitrateBps || 0);
    const hasDerivedBitrate = Boolean(derived && Number.isFinite(bitrateBps));
    const belowSourceResolution =
        (width > 0 && width < sourceSpec.width) ||
        (height > 0 && height < sourceSpec.height);
    const belowSourceFps = sourceFps > 0 && roundedFps > 0 && roundedFps < sourceFps - 5;
    const cleanTransport = packetsLost === 0 && framesDropped === 0;

    if (belowSourceResolution || packetsLost > 0 || framesDropped > 0) {
        return "degraded";
    }
    if (belowSourceFps && cleanTransport && hasDerivedBitrate && bitrateBps < 1_000_000) {
        return "lowMotion";
    }
    return "normal";
}

function updateLiveStatusFromStats(report, codec, derived) {
    const codecName = browserStatsCodecName(codec);
    const width = Number(report.frameWidth || player.videoWidth || 0);
    const height = Number(report.frameHeight || player.videoHeight || 0);
    const fps = Number(report.framesPerSecond || derived?.framesPerSecond || 0);
    const sourceSpec = expectedSourceVideoSpec;

    if (state !== "streaming" || width <= 0 || height <= 0) {
        return;
    }

    const roundedFps = Math.max(0, Math.round(fps));
    if (sourceSpec) {
        const diagnosis = classifyLiveStats(width, height, fps, report, derived, sourceSpec);
        if (diagnosis === "lowMotion") {
            setVideoInfo(t(
                "statusLiveLowMotionWithSource",
                codecName,
                width,
                height,
                sourceSpec.width,
                sourceSpec.height,
                sourceSpec.framesPerSecond
            ));
            return;
        }
        if (diagnosis === "normal") {
            setVideoInfo(t(
                "statusLiveWithSource",
                codecName,
                width,
                height,
                roundedFps,
                sourceSpec.width,
                sourceSpec.height,
                sourceSpec.framesPerSecond
            ));
            return;
        }
        setVideoInfo(t(
            "statusLiveBelowSource",
            codecName,
            width,
            height,
            roundedFps,
            sourceSpec.width,
            sourceSpec.height,
            sourceSpec.framesPerSecond
        ));
        return;
    }
    setVideoInfo(t("statusLiveWithStats", codecName, width, height, roundedFps));
}

async function pollBrowserStats(targetPeer) {
    if (!targetPeer || peer !== targetPeer || typeof targetPeer.getStats !== "function") return;
    const stats = await targetPeer.getStats();
    if (peer !== targetPeer) return;

    const selected = videoInboundStatsFromReport(stats);
    if (!selected) return;

    const now = Number(selected.report.timestamp || performance.now());
    const bytesReceived = Number(selected.report.bytesReceived || 0);
    const framesDecoded = Number(selected.report.framesDecoded || 0);
    let derived = null;
    if (
        browserStatsState.lastTimestamp !== null &&
        now > browserStatsState.lastTimestamp
    ) {
        const elapsedSeconds = (now - browserStatsState.lastTimestamp) / 1000;
        const byteDelta = Math.max(0, bytesReceived - browserStatsState.lastBytesReceived);
        const frameDelta = Math.max(0, framesDecoded - browserStatsState.lastFramesDecoded);
        derived = {
            bitrateBps: elapsedSeconds > 0 ? (byteDelta * 8) / elapsedSeconds : 0,
            framesPerSecond: elapsedSeconds > 0 ? frameDelta / elapsedSeconds : 0
        };
    }
    browserStatsState.lastTimestamp = now;
    browserStatsState.lastBytesReceived = bytesReceived;
    browserStatsState.lastFramesDecoded = framesDecoded;
    updateLiveStatusFromStats(selected.report, selected.codec, derived);
}

function startBrowserStatsLoop(targetPeer) {
    stopBrowserStatsLoop();
    browserStatsState.timer = window.setInterval(() => {
        pollBrowserStats(targetPeer).catch((error) => {
            console.warn("[VoidDisplay] Browser status update failed", error);
        });
    }, browserStatsStatusIntervalMs);
    pollBrowserStats(targetPeer).catch(() => {});
}

function failCodecRequirement(error) {
    terminalStop = true;
    setConnectionStatus(
        t("overlayCodecRequiredTitle"),
        error?.message || t("overlayCodecRequiredBody")
    );
    setLoadingOverlayVisible(false);
    clearReconnectTimer();
    closePeer();
    closeSocketAndClearReference();
    transition("closed");
}

function isCodecErrorReason(reason) {
    return reason === "unsupported_video_codec_offered" || reason === "supported_video_codec_missing";
}

function streamStartupTimeoutError() {
    const error = new Error(t("overlayFirstFrameTimeoutBody"));
    error.streamStartupTimeout = true;
    return error;
}

function isStreamStartupTimeoutError(error) {
    return Boolean(error?.streamStartupTimeout);
}

function hasCurrentVideoFrame() {
    return Number(player.readyState || 0) >= 2;
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
                window.clearTimeout(timeoutID);
                timeoutID = null;
            }
            if (typeof player.removeEventListener === "function") {
                player.removeEventListener("loadeddata", finishIfReady);
                player.removeEventListener("canplay", finishIfReady);
                player.removeEventListener("playing", finishIfReady);
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
        timeoutID = window.setTimeout(() => {
            settle(() => reject(streamStartupTimeoutError()));
        }, timeoutMs);
        if (typeof player.requestVideoFrameCallback === "function") {
            player.requestVideoFrameCallback(() => settle(resolve));
            return;
        }
        player.addEventListener("loadeddata", finishIfReady);
        player.addEventListener("canplay", finishIfReady);
        player.addEventListener("playing", finishIfReady);
    });
}

async function startPeerConnection() {
    closePeer();
    const lifecycleID = ++peerLifecycleID;
    peer = new RTCPeerConnection({ iceServers: bootstrap.iceServers ?? [] });
    const activePeer = peer;
    if (typeof peer.addTransceiver !== "function") {
        throw codecRequirementError(t("overlayCodecRequiredBody"));
    }
    const codecPreferences = receiverCodecPreferences();
    const transceiver = peer.addTransceiver("video", { direction: "recvonly" });
    if (typeof transceiver.setCodecPreferences !== "function") {
        throw codecRequirementError(t("overlayCodecRequiredBody"));
    }
    try {
        transceiver.setCodecPreferences(codecPreferences);
    } catch (error) {
        throw codecRequirementError(error?.message || t("overlayCodecRequiredBody"));
    }

    peer.ontrack = async (event) => {
        if (event.streams && event.streams[0]) {
            const stream = event.streams[0];
            player.srcObject = stream;
            try {
                await waitForFirstVideoFrame();
                if (peer !== activePeer || lifecycleID !== peerLifecycleID || player.srcObject !== stream) {
                    return;
                }
                setConnectionStatus(t("statusLive"), t("overlayLiveBody"));
                setLoadingOverlayVisible(false);
                reconnectIndex = 0;
                transition("streaming");
                startBrowserStatsLoop(activePeer);
            } catch (error) {
                if (isStreamStartupTimeoutError(error)) {
                    console.warn("[VoidDisplay] First video frame timed out", error);
                    closePeer();
                    schedulePeerRetry(t("overlayFirstFrameTimeoutTitle"), error.message || t("overlayFirstFrameTimeoutBody"));
                    return;
                }
                failCodecRequirement(error);
            }
        }
    };

    peer.onicecandidate = (event) => {
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

    peer.onconnectionstatechange = () => {
        if (peer.connectionState === "failed" || peer.connectionState === "disconnected") {
            setProgressOverlay(t("overlayConnectionLostTitle"), t("overlayConnectionLostBody"));
            if (!terminalStop) {
                closeSocketAndClearReference();
                scheduleReconnect();
            }
        }
    };

    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    await sendSignal({ type: "offer", sdp: await waitForLocalOfferSDP() });
    transition("negotiating");
}

function connect() {
    if (terminalStop || state === "closed") {
        return;
    }
    if (isSocketConnectingOrOpen(socket)) {
        return;
    }
    if (!window.WebSocket) {
        setConnectionStatus(t("overlayWebSocketRequiredTitle"), t("overlayWebSocketRequiredBody"));
        setLoadingOverlayVisible(false);
        transition("closed");
        return;
    }
    if (!window.RTCPeerConnection) {
        setConnectionStatus(t("overlayWebRTCRequiredTitle"), t("overlayWebRTCRequiredBody"));
        setLoadingOverlayVisible(false);
        transition("closed");
        return;
    }

    const protocol = window.location.protocol === "https:" ? "wss" : "ws";
    const wsUrl = `${protocol}://${window.location.host}${signalPath}`;
    const ws = new WebSocket(wsUrl);
    socket = ws;
    transition("handshaking");
    setProgressOverlay(t("overlayConnectingTitle"), t("overlayConnectingBody"));

    ws.addEventListener("open", async () => {
        if (socket !== ws) return;
        reconnectIndex = 0;
        clearReconnectTimer();
        transition("signalingReady");
        setConnectionStatus(t("statusSignalingConnected"), t("overlayConnectingBody"));
        await sendSignal({ type: "viewer_ready" });
        try {
            await startPeerConnection();
            setProgressOverlay(t("overlayNegotiatingTitle"), t("overlayNegotiatingBody"));
        } catch (error) {
            if (isCodecRequirementError(error)) {
                failCodecRequirement(error);
                return;
            }
            setProgressOverlay(
                t("overlayNegotiationFailedTitle"),
                error?.message || t("overlayNegotiationFailedFallback")
            );
            closeSocketAndClearReference();
            scheduleReconnect();
        }
    });

    ws.addEventListener("message", async (event) => {
        if (socket !== ws) return;
        if (typeof event.data !== "string") {
            return;
        }

        let payload;
        try {
            payload = JSON.parse(event.data);
        } catch {
            return;
        }

        if (!payload || typeof payload.type !== "string") {
            return;
        }

        switch (payload.type) {
            case "answer":
                if (!peer || typeof payload.sdp !== "string") return;
                try {
                    selectedCodecFromAnswerSDP(payload.sdp);
                    expectedSourceVideoSpec = sourceSpecFromSignal(payload.sourceVideoSpec);
                    await peer.setRemoteDescription({
                        type: "answer",
                        sdp: payload.sdp
                    });
                    setConnectionStatus(t("statusConnected"), t("overlayLiveBody"));
                } catch (error) {
                    failCodecRequirement(error);
                }
                break;
            case "ice_candidate":
                if (!peer || typeof payload.candidate !== "string") return;
                await peer.addIceCandidate({
                    candidate: payload.candidate,
                    sdpMid: payload.sdpMid || null,
                    sdpMLineIndex: Number.isInteger(payload.sdpMLineIndex) ? payload.sdpMLineIndex : 0
                });
                break;
            case "stopped":
                terminalStop = true;
                transition("stopping");
                setConnectionStatus(t("overlaySharingStoppedTitle"), t("overlaySharingStoppedBody"));
                setLoadingOverlayVisible(false);
                closePeer();
                clearReconnectTimer();
                closeSocketAndClearReference();
                transition("closed");
                break;
            case "codec_pending":
                setProgressOverlay(t("overlayCodecPendingTitle"), t("overlayCodecPendingBody"));
                closePeer();
                schedulePeerRetry(t("overlayCodecPendingTitle"), t("overlayCodecPendingBody"));
                break;
            case "error":
                if (isCodecErrorReason(payload.reason)) {
                    failCodecRequirement(new Error(t("overlayCodecAnswerRequiredBody")));
                    break;
                }
                terminalStop = true;
                setConnectionStatus(t("overlayStreamErrorTitle"), payload.reason || t("overlayStreamErrorFallback"));
                setLoadingOverlayVisible(false);
                clearReconnectTimer();
                closePeer();
                closeSocketAndClearReference();
                transition("closed");
                break;
            default:
                break;
        }
    });

    ws.addEventListener("close", () => {
        if (socket !== ws) return;
        socket = null;
        closePeer();
        if (terminalStop || state === "closed" || state === "stopping") {
            setConnectionStatus(t("statusStopped"));
            transition("closed");
            return;
        }
        scheduleReconnect();
    });

    ws.addEventListener("error", () => {
        if (socket !== ws) return;
        setConnectionStatus(t("statusConnectionError"));
    });
}

window.addEventListener("beforeunload", () => {
    terminalStop = true;
    clearReconnectTimer();
    closePeer();
    closeSocketAndClearReference();
});

connect();
