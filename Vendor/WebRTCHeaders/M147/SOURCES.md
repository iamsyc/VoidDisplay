# WebRTC M147 header overlay

This directory contains the local `WebRTC` wrapper target used to import the
macOS WebRTC M147 framework from `stasel/WebRTC` 147.0.0.

The binary framework is supplied by the `WebRTCBinary` SwiftPM binary target
from:

`https://github.com/stasel/WebRTC/releases/download/147.0.0/WebRTC-M147.xcframework.zip`

Expected asset SHA-256:

`49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40`

Official WebRTC source branch used for macOS-only headers:

`refs/branch-heads/7727`

## Header sources

- `include/WebRTC/WebRTC.h` comes from the M147 macOS slice:
  `macos-x86_64_arm64/WebRTC.framework/Versions/A/Headers/WebRTC.h`.
- Headers directly imported by `WebRTC.h` come from the M147 iOS device slice when
  the same file exists there.
- `include/WebRTC/RTCMTLNSVideoView.h` comes from official WebRTC source at
  `refs/branch-heads/7727/sdk/objc/components/renderer/metal/RTCMTLNSVideoView.h`.
  Its local include was normalized from `"RTCVideoRenderer.h"` to
  `<WebRTC/RTCVideoRenderer.h>`.

## Regeneration outline

1. Download the 147.0.0 release zip and verify the SHA-256 listed above.
2. Copy the macOS `WebRTC.h` into `include/WebRTC/`.
3. For every `<WebRTC/...>` import in that umbrella header, copy the matching
   iOS header into `include/WebRTC/`.
4. Replace `RTCMTLNSVideoView.h` with the official branch-heads/7727 source file
   and normalize its WebRTC-local include.
5. Regenerate `SHA256SUMS` from `include/WebRTC/*.h`.

`Package.swift` owns the binary pin. `SHA256SUMS` covers the overlay headers.
SwiftPM and Xcode builds validate header import compatibility.

`WebRTCHeaderOverlayAnchor.c` is an empty compilation unit that lets SwiftPM
model this directory as a C target while all public API surface comes from the
headers under `include/WebRTC/`.
