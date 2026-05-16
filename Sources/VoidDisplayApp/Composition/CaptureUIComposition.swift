import Foundation
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay
import ScreenCaptureKit

@MainActor
package enum CaptureUIComposition {
    package static func previewActions(
        capture: CaptureController,
        displayRuntime: DisplayRuntime
    ) -> CapturePreviewActions {
        CapturePreviewActions(
            sessions: {
                capture.screenPreviewSessions
            },
            previewSession: { sessionID in
                capture.previewSession(for: sessionID)
            },
            previewSessionForDisplayID: { displayID in
                capture.screenPreviewSessions.first(where: { $0.displayID == displayID })
            },
            isStartingDisplayID: { displayID in
                capture.isStarting(displayID: displayID)
            },
            startPreview: { display, metadata in
                try await startRuntimeBackedPreview(
                    display: display,
                    metadata: metadata,
                    capture: capture,
                    displayRuntime: displayRuntime
                )
            },
            attachPreviewSink: { sink, sessionID in
                capture.attachPreviewSink(sink, to: sessionID)
            },
            activatePreviewSession: { sessionID in
                capture.activatePreviewSession(id: sessionID)
            },
            closePreviewSession: { sessionID in
                guard let session = capture.previewSession(for: sessionID) else {
                    return
                }
                guard let surfaceIdentity = displayRuntime.surfaceIdentityForDisplayID(session.displayID) else {
                    return
                }
                await displayRuntime.detachPreviewConsumer(
                    surfaceIdentity: surfaceIdentity
                )
            },
            setPreviewSessionCapturesCursor: { sessionID, capturesCursor in
                try await capture.setPreviewSessionCapturesCursor(
                    id: sessionID,
                    capturesCursor: capturesCursor
                )
            }
        )
    }

    private static func startRuntimeBackedPreview(
        display: SCDisplay,
        metadata _: CapturePreviewDisplayMetadata,
        capture: CaptureController,
        displayRuntime: DisplayRuntime
    ) async throws -> DisplayStartOutcome<UUID> {
        guard let surfaceIdentity = displayRuntime.surfaceIdentityForDisplayID(display.displayID) else {
            throw DisplayRuntimePreviewCaptureError(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }
        let result = await displayRuntime.attachPreviewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .localUI, redactedLabel: "preview"),
            demand: DisplayRuntimeConsumerDemand(
                sourcePixelSize: .init(width: display.width, height: display.height),
                preferredPixelSize: nil,
                maximumPixelSize: nil,
                sourceFramesPerSecond: 60,
                preferredFramesPerSecond: nil,
                capturesCursor: false,
                powerProfile: .automatic,
                latencyPreference: .realtime
            )
        )

        guard result.applyResult.outcome == .applied else {
            _ = await displayRuntime.detachPreviewConsumer(surfaceIdentity: surfaceIdentity)
            throw DisplayRuntimePreviewCaptureError(
                failureCode: result.applyResult.failureCode
                    ?? DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
        guard let session = capture.screenPreviewSessions.first(where: { $0.displayID == display.displayID }) else {
            _ = await displayRuntime.detachPreviewConsumer(surfaceIdentity: surfaceIdentity)
            throw DisplayRuntimePreviewCaptureError(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
        return .started(session.id)
    }

    package static func sharingStatusProvider(sharing: SharingController) -> CaptureSharingStatusProvider {
        CaptureSharingStatusProvider { displayID in
            sharing.isDisplaySharing(displayID: displayID)
        }
    }

    package static func virtualDisplayStatusProvider(
        virtualDisplay: VirtualDisplayController
    ) -> CaptureVirtualDisplayStatusProvider {
        CaptureVirtualDisplayStatusProvider { displayID in
            virtualDisplay.isManagedVirtualDisplay(displayID: displayID)
        }
    }

    package static func catalogActions(
        displayRuntime: DisplayRuntime,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void
    ) -> CaptureCatalogActions {
        CaptureCatalogActions(
            handleAppear: {
                await displayRuntime.handleCatalogAppear(source: .capturePage)
            },
            handleDisappear: {
                await displayRuntime.handleCatalogDisappear(source: .capturePage)
            },
            handleTopologyChanged: {
                await displayRuntime.handleCatalogTopologyChanged()
            },
            requestPermission: {
                await displayRuntime.requestCatalogPermission(source: .capturePage)
            },
            refreshPermission: {
                await displayRuntime.refreshCatalogPermission(source: .capturePage)
            },
            forceRefresh: {
                await displayRuntime.forceRefreshCatalog(source: .capturePage)
            },
            openScreenCapturePrivacySettings: { openURL in
                openScreenCapturePrivacySettings(openURL)
            }
        )
    }
}

private struct DisplayRuntimePreviewCaptureError: LocalizedError {
    let failureCode: String

    var errorDescription: String? {
        failureCode
    }
}
