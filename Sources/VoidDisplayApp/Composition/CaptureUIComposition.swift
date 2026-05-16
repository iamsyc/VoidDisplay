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
            attachDiagnosticsRecorder: { sessionID in
                guard let session = capture.previewSession(for: sessionID) else { return nil }
                guard let surfaceIdentity = displayRuntime.surfaceIdentityForDisplayID(session.displayID) else {
                    return nil
                }
                let result = await displayRuntime.attachDiagnosticsRecorderConsumer(
                    surfaceIdentity: surfaceIdentity,
                    owner: .init(source: .diagnostics, redactedLabel: "diagnostics-recorder"),
                    demand: diagnosticsRecorderDemand(for: session)
                )
                guard result.applyResult.outcome == .applied else {
                    _ = await displayRuntime.detachDiagnosticsRecorderConsumer(leaseID: result.lease.id)
                    return nil
                }
                return result.lease.id.rawValue
            },
            detachDiagnosticsRecorder: { leaseToken in
                _ = await displayRuntime.detachDiagnosticsRecorderConsumer(
                    leaseID: DisplayRuntimeConsumerLeaseID(rawValue: leaseToken)
                )
            },
            closePreviewSession: { sessionID in
                guard let session = capture.previewSession(for: sessionID) else {
                    return
                }
                guard let surfaceIdentity = displayRuntime.surfaceIdentityForDisplayID(session.displayID) else {
                    return
                }
                displayRuntime.detachPreviewConsumer(
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

    private static func diagnosticsRecorderDemand(
        for session: ScreenPreviewSession
    ) -> DisplayRuntimeConsumerDemand {
        let sourcePixelSize = pixelSize(from: session.resolutionText)
        let preferredPixelSize = sourcePixelSize.map { size in
            DisplayRuntimePixelSize(
                width: min(size.width, 1280),
                height: min(size.height, 720)
            )
        }
        return DisplayRuntimeConsumerDemand(
            sourcePixelSize: sourcePixelSize,
            preferredPixelSize: preferredPixelSize,
            sourceFramesPerSecond: 60,
            preferredFramesPerSecond: 15,
            capturesCursor: session.capturesCursor,
            powerProfile: .powerEfficient,
            latencyPreference: .recording
        )
    }

    private static func pixelSize(from resolutionText: String) -> DisplayRuntimePixelSize? {
        let separators: [Character] = ["x", "X", "×", ","]
        guard let separator = separators.first(where: resolutionText.contains) else { return nil }
        let parts = resolutionText.split(separator: separator, maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0
        else {
            return nil
        }
        return DisplayRuntimePixelSize(width: width, height: height)
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
            _ = displayRuntime.detachConsumer(leaseID: result.lease.id)
            throw DisplayRuntimePreviewCaptureError(
                failureCode: result.applyResult.failureCode
                    ?? DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
        guard let session = capture.screenPreviewSessions.first(where: { $0.displayID == display.displayID }) else {
            _ = displayRuntime.detachConsumer(leaseID: result.lease.id)
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
