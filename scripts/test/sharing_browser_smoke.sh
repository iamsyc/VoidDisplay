#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sharing_browser_smoke.sh <display-url>

Environment:
  SHARING_BROWSER_SMOKE_TIMEOUT_SECONDS  Timeout in seconds. Default: 30
  SHARING_BROWSER_SMOKE_BROWSER          chromium, firefox, or webkit. Default: chromium
  SHARING_BROWSER_SMOKE_HEADLESS         1 for headless, 0 for visible browser. Default: 1
  NODE_BIN                               Node executable. Default: node
EOF
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 64
fi

display_url="$1"
timeout_seconds="${SHARING_BROWSER_SMOKE_TIMEOUT_SECONDS:-30}"
browser_name="${SHARING_BROWSER_SMOKE_BROWSER:-chromium}"
headless="${SHARING_BROWSER_SMOKE_HEADLESS:-1}"
node_bin="${NODE_BIN:-node}"

case "${display_url}" in
  http://*|https://*) ;;
  *)
    echo "Expected an HTTP display URL, got: ${display_url}" >&2
    exit 64
    ;;
esac

if ! command -v "${node_bin}" >/dev/null 2>&1; then
  echo "Node executable not found. Install Node or set NODE_BIN." >&2
  exit 78
fi

"${node_bin}" - "${display_url}" "${timeout_seconds}" "${browser_name}" "${headless}" <<'NODE'
const [displayURL, timeoutRaw, browserName, headlessRaw] = process.argv.slice(2);
const timeoutSeconds = Number(timeoutRaw);
const timeoutMs = Number.isFinite(timeoutSeconds) && timeoutSeconds > 0
  ? timeoutSeconds * 1000
  : 30_000;
const headless = headlessRaw !== "0";

function loadPlaywright() {
  try {
    return require("playwright");
  } catch (playwrightError) {
    try {
      return require("playwright-core");
    } catch (playwrightCoreError) {
      console.error(JSON.stringify({
        error: "Playwright is not installed. Install playwright or playwright-core, then retry.",
        requireErrors: [
          playwrightError.message,
          playwrightCoreError.message
        ]
      }, null, 2));
      process.exit(78);
    }
  }
}

function trimMessages(messages) {
  return messages.slice(Math.max(messages.length - 30, 0));
}

async function readDiagnostics(page) {
  return page.evaluate(() => {
    const videos = [...document.querySelectorAll("video")].map((video) => ({
      readyState: video.readyState,
      paused: video.paused,
      ended: video.ended,
      currentTime: video.currentTime,
      videoWidth: video.videoWidth,
      videoHeight: video.videoHeight,
      muted: video.muted
    }));

    return {
      url: window.location.href,
      title: document.title,
      smoke: window.__voiddisplaySmoke ?? null,
      videos,
      bodyText: document.body?.innerText?.slice(0, 1000) ?? ""
    };
  }).catch((error) => ({ diagnosticsError: error.message }));
}

async function main() {
  const playwright = loadPlaywright();
  const browserType = playwright[browserName];
  if (!browserType) {
    console.error(`Unsupported browser: ${browserName}`);
    process.exit(64);
  }

  const browser = await browserType.launch({ headless });
  const page = await browser.newPage();
  const consoleMessages = [];

  page.on("console", (message) => {
    const type = message.type();
    if (type === "error" || type === "warning") {
      consoleMessages.push(`${type}: ${message.text()}`);
    }
  });
  page.on("pageerror", (error) => {
    consoleMessages.push(`pageerror: ${error.message}`);
  });

  try {
    await page.addInitScript(() => {
      window.__voiddisplaySmoke = {
        websocketOpen: false,
        peerConnected: false,
        connectionStates: [],
        iceConnectionStates: [],
        errors: []
      };

      const NativeWebSocket = window.WebSocket;
      if (NativeWebSocket) {
        const SmokeWebSocket = function (...args) {
          const socket = new NativeWebSocket(...args);
          socket.addEventListener("open", () => {
            window.__voiddisplaySmoke.websocketOpen = true;
          });
          socket.addEventListener("error", () => {
            window.__voiddisplaySmoke.errors.push("websocket_error");
          });
          return socket;
        };
        SmokeWebSocket.prototype = NativeWebSocket.prototype;
        Object.setPrototypeOf(SmokeWebSocket, NativeWebSocket);
        Object.defineProperty(window, "WebSocket", {
          value: SmokeWebSocket,
          configurable: true,
          writable: true
        });
      }

      const NativeRTCPeerConnection = window.RTCPeerConnection;
      if (NativeRTCPeerConnection) {
        const SmokeRTCPeerConnection = function (...args) {
          const peerConnection = new NativeRTCPeerConnection(...args);
          const recordState = () => {
            const state = peerConnection.connectionState;
            const iceState = peerConnection.iceConnectionState;
            if (state) {
              window.__voiddisplaySmoke.connectionStates.push(state);
            }
            if (iceState) {
              window.__voiddisplaySmoke.iceConnectionStates.push(iceState);
            }
            if (state === "connected" || iceState === "connected" || iceState === "completed") {
              window.__voiddisplaySmoke.peerConnected = true;
            }
          };
          peerConnection.addEventListener("connectionstatechange", recordState);
          peerConnection.addEventListener("iceconnectionstatechange", recordState);
          recordState();
          return peerConnection;
        };
        SmokeRTCPeerConnection.prototype = NativeRTCPeerConnection.prototype;
        Object.setPrototypeOf(SmokeRTCPeerConnection, NativeRTCPeerConnection);
        Object.defineProperty(window, "RTCPeerConnection", {
          value: SmokeRTCPeerConnection,
          configurable: true,
          writable: true
        });
      }
    });

    await page.goto(displayURL, { waitUntil: "domcontentloaded", timeout: timeoutMs });
    await page.waitForFunction(() => {
      const smoke = window.__voiddisplaySmoke ?? {};
      const video = document.querySelector("video");
      if (!video) {
        return false;
      }
      video.muted = true;
      const playResult = video.play();
      if (playResult && typeof playResult.catch === "function") {
        playResult.catch(() => {});
      }
      return smoke.websocketOpen === true
        && smoke.peerConnected === true
        && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
        && video.videoWidth > 0
        && video.videoHeight > 0
        && video.paused === false
        && video.ended === false;
    }, undefined, { timeout: timeoutMs, polling: 250 });

    const diagnostics = await readDiagnostics(page);
    console.log(JSON.stringify({
      ok: true,
      diagnostics,
      consoleMessages: trimMessages(consoleMessages)
    }, null, 2));
  } catch (error) {
    const diagnostics = await readDiagnostics(page);
    console.error(JSON.stringify({
      ok: false,
      error: error.message,
      diagnostics,
      consoleMessages: trimMessages(consoleMessages)
    }, null, 2));
    process.exitCode = 1;
  } finally {
    await browser.close().catch(() => {});
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
