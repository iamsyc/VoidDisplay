import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay
import ScreenCaptureKit

@MainActor
package enum CaptureUIComposition {
    package static func monitoringActions(
        capture: CaptureController,
        displayRuntime: DisplayRuntime
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
                try await startRuntimeBackedMonitoring(
                    display: display,
                    metadata: metadata,
                    capture: capture,
                    displayRuntime: displayRuntime
                )
            },
            attachPreviewSink: { sink, sessionID in
                capture.attachPreviewSink(sink, to: sessionID)
            },
            activateMonitoringSession: { sessionID in
                capture.activateMonitoringSession(id: sessionID)
            },
            attachDiagnosticsRecorder: { sessionID in
                guard let session = capture.monitoringSession(for: sessionID) else { return nil }
                let result = await displayRuntime.attachDiagnosticsRecorderConsumer(
                    surfaceIdentity: .physicalDisplay(displayID: session.displayID),
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
            closeMonitoringSession: { sessionID in
                if let session = capture.monitoringSession(for: sessionID) {
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

    private static func diagnosticsRecorderDemand(
        for session: ScreenMonitoringSession
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
