(function registerDisplayPageUI(root) {
    "use strict";

    const namespace = root.VoidDisplayBrowser || {};
    root.VoidDisplayBrowser = namespace;

    function resolveLocale(navigatorObject) {
        const preferredLocales = Array.isArray(navigatorObject?.languages) && navigatorObject.languages.length > 0
            ? navigatorObject.languages
            : [navigatorObject?.language || "en"];
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

    function parseBootstrapJSON(text) {
        if (!text) {
            return { iceServers: [] };
        }
        try {
            const parsed = JSON.parse(text);
            const iceServers = Array.isArray(parsed?.iceServers) ? parsed.iceServers : [];
            return { iceServers };
        } catch {
            return { iceServers: [] };
        }
    }

    function createDisplayPageUI({ documentObject, navigatorObject, messagesObject }) {
        const videoInfoEl = documentObject.getElementById("video-info");
        const connectionStatusTitleEl = documentObject.getElementById("connection-status-title");
        const connectionStatusDetailEl = documentObject.getElementById("connection-status-detail");
        const overlayEl = documentObject.getElementById("overlay");
        const heroEyebrowEl = documentObject.getElementById("hero-eyebrow");
        const footnoteEl = documentObject.getElementById("footnote");
        const player = documentObject.getElementById("player");
        const stage = documentObject.querySelector(".stage");
        const scaleModeBtn = documentObject.getElementById("scale-mode-btn");
        const fullscreenBtn = documentObject.getElementById("fullscreen-btn");
        const locale = resolveLocale(navigatorObject);
        const currentMessages = messagesObject[locale] || messagesObject.en;
        let originalScaleEnabled = false;

        function t(key, ...args) {
            const value = currentMessages[key];
            if (typeof value === "function") {
                return value(...args);
            }
            return value ?? messagesObject.en[key] ?? "";
        }

        function applyStaticCopy() {
            documentObject.title = t("pageTitle");
            if (heroEyebrowEl) {
                heroEyebrowEl.textContent = t("heroEyebrow");
            }
            if (footnoteEl) {
                footnoteEl.textContent = t("footnote");
            }
        }

        function setVideoInfo(text) {
            if (!videoInfoEl) return;
            videoInfoEl.textContent = String(text || "");
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

        function setLoadingOverlayVisible(visible) {
            if (overlayEl) {
                overlayEl.hidden = !visible;
            }
        }

        function setProgressOverlay(title, body) {
            setConnectionStatus(title, body);
            setLoadingOverlayVisible(true);
        }

        function applyScaleMode() {
            documentObject.body.classList.toggle("mode-native", originalScaleEnabled);
            if (scaleModeBtn) {
                scaleModeBtn.textContent = originalScaleEnabled ? t("scaleFit") : t("scaleOriginal");
            }
        }

        function syncFullscreenButtonLabel() {
            if (!fullscreenBtn) return;
            fullscreenBtn.textContent = documentObject.fullscreenElement ? t("fullscreenExit") : t("fullscreenEnter");
        }

        async function toggleFullscreen() {
            if (!documentObject.fullscreenEnabled || !stage) return;
            try {
                if (documentObject.fullscreenElement) {
                    await documentObject.exitFullscreen();
                } else {
                    await stage.requestFullscreen();
                }
            } catch {
                // The button label remains synchronized with the actual fullscreen state.
            }
        }

        scaleModeBtn?.addEventListener("click", () => {
            originalScaleEnabled = !originalScaleEnabled;
            applyScaleMode();
        });
        fullscreenBtn?.addEventListener("click", toggleFullscreen);
        documentObject.addEventListener("fullscreenchange", syncFullscreenButtonLabel);

        applyStaticCopy();
        applyScaleMode();
        syncFullscreenButtonLabel();

        return Object.freeze({
            player,
            setConnectionStatus,
            setLoadingOverlayVisible,
            setProgressOverlay,
            setVideoInfo,
            t
        });
    }

    namespace.ui = Object.freeze({
        createDisplayPageUI,
        parseBootstrapJSON,
        resolveLocale
    });
})(globalThis);
