import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay
import ScreenCaptureKit

@MainActor
package enum CaptureUIComposition {
    package static func monitoringActions(
        capture: CaptureController,
        displayRuntime: DisplayRuntime? = nil
    ) -> CaptureMonitoringActions {
        CaptureMonitoringActions(
            sessions: {
                capture.screenCaptureSessions
            },
            monitoringSession: { sessionID in
                capture.monitoringSession(for: sessionID)
            },
            monitoringSessionForDisplayID: { displayID in
                capture.screenCaptureSessions.first(where: { $0.displayID == displayID })
            },
            isStartingDisplayID: { displayID in
                capture.isStarting(displayID: displayID)
            },
            startMonitoring: { display, metadata in
                if let displayRuntime {
                    return try await startRuntimeBackedMonitoring(
                        display: display,
                        metadata: metadata,
                        capture: capture,
                        displayRuntime: displayRuntime
                    )
                }
                return try await capture.startMonitoring(display: display, metadata: metadata)
            },
            attachPreviewSink: { sink, sessionID in
                capture.attachPreviewSink(sink, to: sessionID)
            },
            activateMonitoringSession: { sessionID in
                capture.activateMonitoringSession(id: sessionID)
            },
            closeMonitoringSession: { sessionID in
                if let displayRuntime,
                   let session = capture.monitoringSession(for: sessionID) {
                    let result = displayRuntime.detachMonitorConsumer(
                        surfaceIdentity: .physicalDisplay(displayID: session.displayID)
                    )
                    if result.releasedLease != nil {
                        return
                    }
                }
                capture.closeMonitoringSession(id: sessionID)
            },
            setMonitoringSessionCapturesCursor: { sessionID, capturesCursor in
                try await capture.setMonitoringSessionCapturesCursor(
                    id: sessionID,
                    capturesCursor: capturesCursor
                )
            }
        )
    }

    private static func startRuntimeBackedMonitoring(
        display: SCDisplay,
        metadata _: CaptureMonitoringDisplayMetadata,
        capture: CaptureController,
        displayRuntime: DisplayRuntime
    ) async throws -> DisplayStartOutcome<UUID> {
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: display.displayID)
        let result = await displayRuntime.attachMonitorConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .localUI, redactedLabel: "monitor"),
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
            throw DisplayRuntimeMonitorCaptureError(
                failureCode: result.applyResult.failureCode
                    ?? DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
        guard let session = capture.screenCaptureSessions.first(where: { $0.displayID == display.displayID }) else {
            _ = displayRuntime.detachConsumer(leaseID: result.lease.id)
            throw DisplayRuntimeMonitorCaptureError(
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

    package static func catalogActions(screenCatalog: ScreenCatalogOrchestrator) -> CaptureCatalogActions {
        CaptureCatalogActions(
            handleAppear: {
                await screenCatalog.handleAppear(source: .capturePage)
            },
            handleDisappear: {
                await screenCatalog.handleDisappear(source: .capturePage)
            },
            handleTopologyChanged: {
                await screenCatalog.handleTopologyChanged()
            },
            requestPermission: {
                await screenCatalog.requestPermission(source: .capturePage)
            },
            refreshPermission: {
                await screenCatalog.refreshPermission(source: .capturePage)
            },
            forceRefresh: {
                await screenCatalog.forceRefresh(source: .capturePage)
            },
            openScreenCapturePrivacySettings: { openURL in
                screenCatalog.openScreenCapturePrivacySettings(openURL: openURL)
            }
        )
    }
}

private struct DisplayRuntimeMonitorCaptureError: LocalizedError {
    let failureCode: String

    var errorDescription: String? {
        failureCode
    }
}
