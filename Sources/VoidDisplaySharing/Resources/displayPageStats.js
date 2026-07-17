(function registerDisplayPageStats(root) {
    "use strict";

    const namespace = root.VoidDisplayBrowser || {};
    root.VoidDisplayBrowser = namespace;

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
            if (String(codec.mimeType).toLowerCase() !== "video/av1") continue;
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

    function deriveBrowserStatsSample(previousState, report, fallbackTimestamp) {
        const timestamp = Number(report.timestamp || fallbackTimestamp);
        const bytesReceived = Number(report.bytesReceived || 0);
        const framesDecoded = Number(report.framesDecoded || 0);
        let derived = null;

        if (previousState.lastTimestamp !== null && timestamp > previousState.lastTimestamp) {
            const elapsedSeconds = (timestamp - previousState.lastTimestamp) / 1000;
            const byteDelta = Math.max(0, bytesReceived - previousState.lastBytesReceived);
            const frameDelta = Math.max(0, framesDecoded - previousState.lastFramesDecoded);
            derived = {
                bitrateBps: elapsedSeconds > 0 ? (byteDelta * 8) / elapsedSeconds : 0,
                framesPerSecond: elapsedSeconds > 0 ? frameDelta / elapsedSeconds : 0
            };
        }

        return {
            derived,
            nextState: {
                lastBytesReceived: bytesReceived,
                lastFramesDecoded: framesDecoded,
                lastTimestamp: timestamp
            }
        };
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
        let sampleState = {
            lastBytesReceived: null,
            lastFramesDecoded: null,
            lastTimestamp: null
        };

        function reset() {
            sampleState = {
                lastBytesReceived: null,
                lastFramesDecoded: null,
                lastTimestamp: null
            };
        }

        function stop() {
            if (timer) {
                windowObject.clearInterval(timer);
                timer = null;
            }
            reset();
        }

        function updateLiveStatus(report, codec, derived) {
            const codecName = browserStatsCodecName(codec);
            const width = Number(report.frameWidth || player.videoWidth || 0);
            const height = Number(report.frameHeight || player.videoHeight || 0);
            const fps = Number(report.framesPerSecond || derived?.framesPerSecond || 0);
            const sourceSpec = getSourceSpec();

            if (getState() !== "streaming" || width <= 0 || height <= 0) {
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

        async function poll(targetPeer) {
            if (!targetPeer || getPeer() !== targetPeer || typeof targetPeer.getStats !== "function") return;
            const stats = await targetPeer.getStats();
            if (getPeer() !== targetPeer) return;

            const selected = videoInboundStatsFromReport(stats);
            if (!selected) return;

            const sample = deriveBrowserStatsSample(
                sampleState,
                selected.report,
                performanceObject.now()
            );
            sampleState = sample.nextState;
            updateLiveStatus(selected.report, selected.codec, sample.derived);
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
        videoInboundStatsFromReport
    });
})(globalThis);
