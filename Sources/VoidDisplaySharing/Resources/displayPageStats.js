(function registerDisplayPageStats(root) {
    "use strict";

    const namespace = root.VoidDisplayBrowser || {};
    root.VoidDisplayBrowser = namespace;

    let latestDiagnostics = null;

    function browserStatsCodecName(codec) {
        const mimeType = String(codec?.mimeType || "").toLowerCase();
        if (mimeType === "video/h265") return "H.265";
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
            if (String(codec.mimeType).toLowerCase() !== "video/h265") continue;
            return { report, codec };
        }
        return null;
    }

    function classifyLiveStats(width, height, fps, report, derived, sourceSpec) {
        if (!sourceSpec) return "normal";
        const roundedFps = Math.max(0, Math.round(fps));
        const sourceFps = Number(sourceSpec.framesPerSecond || 0);
        const packetsLost = derived?.packetsLost;
        const framesDropped = derived?.framesDropped;
        const bitrateBps = derived?.bitrateBps;
        const hasDerivedBitrate = Boolean(derived && Number.isFinite(bitrateBps));
        const belowSourceResolution =
            (width > 0 && width < sourceSpec.width) ||
            (height > 0 && height < sourceSpec.height);
        const belowSourceFps = sourceFps > 0 && roundedFps > 0 && roundedFps < sourceFps - 5;
        const cleanTransport = packetsLost !== null && packetsLost <= 0 && framesDropped === 0;

        if (belowSourceResolution || packetsLost > 0 || framesDropped > 0) {
            return "degraded";
        }
        if (belowSourceFps && cleanTransport && hasDerivedBitrate && bitrateBps < 1_000_000) {
            return "lowMotion";
        }
        return "normal";
    }

    const counterFields = [
        "bytesReceived", "framesDecoded", "framesDropped", "packetsLost",
        "totalDecodeTime", "totalProcessingDelay", "jitterBufferDelay", "jitterBufferEmittedCount"
    ];

    function finiteNumber(value) {
        return typeof value === "number" && Number.isFinite(value) ? value : null;
    }

    function deriveBrowserStatsSample(previousState, report, fallbackTimestamp, playback = null) {
        const timestamp = finiteNumber(report.timestamp) ?? fallbackTimestamp;
        const counters = Object.fromEntries(counterFields.map((key) => [key, finiteNumber(report[key])]));
        counters.presentationDrops = finiteNumber(playback?.droppedVideoFrames);
        const nextState = { timestamp, id: report.id, ssrc: report.ssrc, counters };
        const previous = previousState?.counters;
        const reset = !previous || report.id !== previousState.id || report.ssrc !== previousState.ssrc ||
            timestamp <= previousState.timestamp || Object.keys(counters).some((key) =>
                key !== "packetsLost" && counters[key] !== null && previous[key] !== null &&
                counters[key] < previous[key]);
        if (reset) return { derived: null, nextState };

        const delta = (key) => counters[key] === null || previous[key] === null ? null : counters[key] - previous[key];
        const rate = (key, scale) => delta(key) === null ? null : delta(key) * scale / (timestamp - previousState.timestamp);
        const meanMs = (total, count) => delta(total) === null || !(delta(count) > 0) ? null : 1000 * delta(total) / delta(count);
        return {
            derived: {
                bitrateBps: rate("bytesReceived", 8000),
                framesPerSecond: rate("framesDecoded", 1000),
                packetsLost: delta("packetsLost"),
                framesDropped: delta("framesDropped"),
                presentationDrops: delta("presentationDrops"),
                decodeMs: meanMs("totalDecodeTime", "framesDecoded"),
                receiveToDecodeMs: meanMs("totalProcessingDelay", "framesDecoded"),
                jitterBufferMs: meanMs("jitterBufferDelay", "jitterBufferEmittedCount")
            },
            nextState
        };
    }

    function selectedRoundTripTimeMs(stats, report) {
        const transport = stats.get(report.transportId);
        const pair = stats.get(transport?.selectedCandidatePairId);
        const seconds = finiteNumber(pair?.currentRoundTripTime);
        return seconds === null ? null : seconds * 1000;
    }

    function createBrowserStatsMonitor({
        windowObject,
        performanceObject,
        player,
        getPeer,
        getSourceSpec,
        getState,
        setVideoInfo,
        t
    }) {
        const statusIntervalMs = 2000;
        let timer = null;
        let generation = 0;
        let polling = false;
        let sampleState = null;

        function stop() {
            generation += 1;
            if (timer !== null) windowObject.clearInterval(timer);
            timer = null;
            polling = false;
            sampleState = null;
            latestDiagnostics = null;
        }

        function updateLiveStatus(report, codec, derived) {
            const codecName = browserStatsCodecName(codec);
            const width = Number(report.frameWidth || player.videoWidth || 0);
            const height = Number(report.frameHeight || player.videoHeight || 0);
            // Use the same measured interval as the numeric diagnostics. A browser's
            // startup estimate may report hundreds of FPS for a short decode burst.
            const fps = finiteNumber(derived?.framesPerSecond);
            const sourceSpec = getSourceSpec();

            if (getState() !== "streaming" || width <= 0 || height <= 0) {
                return;
            }

            const roundedFps = fps === null ? "—" : Math.max(0, Math.round(fps));
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

        async function poll(targetPeer) {
            if (polling || !targetPeer || getPeer() !== targetPeer || typeof targetPeer.getStats !== "function") return;
            const token = generation;
            polling = true;
            try {
                const stats = await targetPeer.getStats();
                if (token !== generation || getPeer() !== targetPeer) return;
                const selected = videoInboundStatsFromReport(stats);
                if (!selected) return;
                const sample = deriveBrowserStatsSample(
                    sampleState, selected.report, performanceObject.now(), player.getVideoPlaybackQuality?.()
                );
                sampleState = sample.nextState;
                // Numeric, connection-local evidence only; no SDP, addresses or credentials.
                latestDiagnostics = Object.freeze({
                    timestamp: sample.nextState.timestamp,
                    interval: sample.derived && Object.freeze(sample.derived),
                    roundTripTimeMs: selectedRoundTripTimeMs(stats, selected.report)
                });
                updateLiveStatus(selected.report, selected.codec, sample.derived);
            } finally {
                if (token === generation) polling = false;
            }
        }

        function start(targetPeer) {
            stop();
            timer = windowObject.setInterval(() => {
                poll(targetPeer).catch((error) => {
                    console.warn("[VoidDisplay] Browser status update failed", error);
                });
            }, statusIntervalMs);
            poll(targetPeer).catch(() => {});
        }

        return Object.freeze({ start, stop });
    }

    namespace.stats = Object.freeze({
        browserStatsCodecName,
        classifyLiveStats,
        createBrowserStatsMonitor,
        deriveBrowserStatsSample,
        sourceSpecFromSignal,
        selectedRoundTripTimeMs,
        getLatestDiagnostics: () => latestDiagnostics,
        videoInboundStatsFromReport
    });
})(globalThis);
