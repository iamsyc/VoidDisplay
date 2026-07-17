(function registerDisplayPageCodec(root) {
    "use strict";

    const namespace = root.VoidDisplayBrowser || {};
    root.VoidDisplayBrowser = namespace;

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

    function receiverCodecPreferences(receiverConstructor, requiredMessage) {
        if (!receiverConstructor || typeof receiverConstructor.getCapabilities !== "function") {
            throw codecRequirementError(requiredMessage);
        }
        const capabilities = receiverConstructor.getCapabilities("video");
        const allCodecs = Array.isArray(capabilities?.codecs) ? capabilities.codecs : [];
        const av1Codecs = allCodecs.filter(isAV1Codec);
        if (av1Codecs.length === 0) {
            throw codecRequirementError(requiredMessage);
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

    function selectedCodecFromAnswerSDP(sdp, requiredMessage) {
        const codecNames = videoCodecNamesFromSDP(sdp);
        const primaryCodecs = codecNames.filter((name) => name !== "rtx");
        const supportedPrimaryCodecs = [...new Set(primaryCodecs.filter((name) => name === "av1"))];
        const hasUnexpectedVideoCodec = primaryCodecs.some((name) => name !== "av1");
        if (supportedPrimaryCodecs.length !== 1 || hasUnexpectedVideoCodec) {
            throw new Error(requiredMessage);
        }
        return supportedPrimaryCodecs[0];
    }

    namespace.codec = Object.freeze({
        codecPayloadType,
        codecRequirementError,
        isAV1Codec,
        isCodecRequirementError,
        isRetransmissionCodec,
        normalizedVideoCodecName,
        receiverCodecPreferences,
        rtxAptPayloadType,
        rtxCodecsForPrimaryCodecs,
        selectedCodecFromAnswerSDP,
        videoCodecNamesFromSDP
    });
})(globalThis);
