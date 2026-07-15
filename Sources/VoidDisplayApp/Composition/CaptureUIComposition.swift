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
        displayRuntime: DisplayRuntime,
        capturePerformancePreferences: CapturePerformancePreferences
    ) -> CapturePreviewActions {
        CapturePreviewActions(
            sessions: {
                capture.screenPreviewSessions
            },
            previewSession: { previewID in
                previewSession(
                    previewID: previewID,
                    capture: capture,
                    displayRuntime: displayRuntime
                )
            },
            previewState: { previewID in
                previewState(previewID: previewID, displayRuntime: displayRuntime)
            },
            previewIDForDisplayID: { displayID in
                previewID(displayID: displayID, displayRuntime: displayRuntime)
            },
            isStartingDisplayID: { displayID in
                capture.isStarting(displayID: displayID)
            },
            startPreview: { display, metadata in
                try await startRuntimeBackedPreview(
                    display: display,
                    metadata: metadata,
                    capture: capture,
                    displayRuntime: displayRuntime,
                    powerProfile: capturePerformancePreferences.mode.runtimeCapturePowerProfile
                )
            },
            attachPreviewSink: { sink, previewID in
                guard let session = previewSession(
                    previewID: previewID,
                    capture: capture,
                    displayRuntime: displayRuntime
                ) else {
                    return
                }
                capture.attachPreviewSink(sink, to: session.id)
            },
            activatePreviewSession: { previewID in
                guard let session = previewSession(
                    previewID: previewID,
                    capture: capture,
                    displayRuntime: displayRuntime
                ) else {
                    return
                }
                capture.activatePreviewSession(id: session.id)
            },
            waitForPreviewResolution: { previewID in
                let lease = await displayRuntime.waitForPreviewConsumerResolution(
                    leaseID: .init(rawValue: previewID.rawValue)
                )
                return previewState(lease: lease)
            },
            retryPreview: { previewID in
                let lease = await displayRuntime.retryPreviewConsumer(
                    leaseID: .init(rawValue: previewID.rawValue)
                )
                return previewState(lease: lease)
            },
            closePreview: { previewID in
                _ = await displayRuntime.detachPreviewConsumer(
                    leaseID: .init(rawValue: previewID.rawValue)
                )
            },
            setPreviewCapturesCursor: { previewID, capturesCursor in
                let leaseID = DisplayRuntimeConsumerLeaseID(rawValue: previewID.rawValue)
                guard let lease = displayRuntime.consumerLease(leaseID: leaseID),
                      let applyResult = await displayRuntime.updatePreviewConsumerDemand(
                        leaseID: leaseID,
                        demand: lease.demand.replacing(capturesCursor: capturesCursor)
                      ),
                      applyResult.outcome == .applied
                else {
                    throw DisplayRuntimePreviewCaptureError(
                        failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
                    )
                }
            }
        )
    }

    private static func startRuntimeBackedPreview(
        display: SCDisplay,
        metadata _: CapturePreviewDisplayMetadata,
        capture: CaptureController,
        displayRuntime: DisplayRuntime,
        powerProfile: DisplayRuntimeCapturePowerProfile
    ) async throws -> DisplayStartOutcome<CapturePreviewID> {
        guard let surfaceIdentity = displayRuntime.surfaceIdentityForDisplayID(display.displayID) else {
            throw DisplayRuntimePreviewCaptureError(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
        }
        let outcome = await displayRuntime.attachPreviewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .localUI, redactedLabel: "preview"),
            demand: DisplayRuntimeConsumerDemand(
                sourcePixelSize: .init(width: display.width, height: display.height),
                preferredPixelSize: nil,
                maximumPixelSize: nil,
                sourceFramesPerSecond: 60,
                preferredFramesPerSecond: nil,
                capturesCursor: false,
                powerProfile: powerProfile,
                latencyPreference: .realtime
            )
        )

        guard case let .attached(lease, applyResult) = outcome else {
            guard case let .rejected(failureCode) = outcome else {
                throw DisplayRuntimePreviewCaptureError(
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
                )
            }
            throw DisplayRuntimePreviewCaptureError(
                failureCode: failureCode
            )
        }
        guard applyResult.outcome == .applied else {
            _ = await displayRuntime.detachPreviewConsumer(leaseID: lease.id)
            throw DisplayRuntimePreviewCaptureError(
                failureCode: applyResult.failureCode
                    ?? DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
        guard capture.screenPreviewSessions.contains(where: { $0.displayID == display.displayID }) else {
            _ = await displayRuntime.detachPreviewConsumer(leaseID: lease.id)
            throw DisplayRuntimePreviewCaptureError(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        }
        return .started(CapturePreviewID(rawValue: lease.id.rawValue))
    }

    private static func previewSession(
        previewID: CapturePreviewID,
        capture: CaptureController,
        displayRuntime: DisplayRuntime
    ) -> ScreenPreviewSession? {
        guard let displayID = displayRuntime.consumerLease(
            leaseID: .init(rawValue: previewID.rawValue)
        )?.resolvedDisplayID else {
            return nil
        }
        return capture.screenPreviewSessions.first { $0.displayID == displayID }
    }

    private static func previewID(
        displayID: CGDirectDisplayID,
        displayRuntime: DisplayRuntime
    ) -> CapturePreviewID? {
        guard let surfaceIdentity = displayRuntime.surfaceIdentityForDisplayID(displayID),
              let lease = displayRuntime.currentConsumerLeaseSnapshot().first(where: {
                  $0.surfaceIdentity == surfaceIdentity
                      && $0.kind == .preview
                      && $0.state != .released
              }) else {
            return nil
        }
        return CapturePreviewID(rawValue: lease.id.rawValue)
    }

    private static func previewState(
        previewID: CapturePreviewID,
        displayRuntime: DisplayRuntime
    ) -> CapturePreviewState {
        previewState(
            lease: displayRuntime.consumerLease(
                leaseID: .init(rawValue: previewID.rawValue)
            )
        )
    }

    private static func previewState(
        lease: DisplayRuntimeConsumerLease?
    ) -> CapturePreviewState {
        guard let lease else { return .released }
        switch lease.state {
        case .attaching, .restarting, .draining:
            return .restarting
        case .attached:
            return .active
        case .failed:
            return .failed(
                failureCode: lease.lastFailureCode
                    ?? DisplayRuntimeCaptureIntentFailureCode.applyFailed
            )
        case .released:
            return .released
        }
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
