@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
import Foundation
import Testing

@Suite
struct DisplaySurfacePresentationMapperTests {
    @Test func mapsManagedVirtualSurfaceStatusWithoutRawIdentity() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000013"))
        let displayID: DisplayRuntimeDisplayID = 4242
        let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let monitorLease = makeLease(
            surfaceIdentity: identity,
            displayID: displayID,
            kind: .monitor,
            state: .attached
        )
        let lanLease = makeLease(
            surfaceIdentity: identity,
            displayID: displayID,
            kind: .lanWebView,
            state: .attached,
            activeViewerCount: 3
        )
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                DisplaySurface(
                    identity: identity,
                    kind: .managedVirtualDisplay,
                    currentDisplayID: displayID,
                    isAuxiliary: false,
                    catalog: nil,
                    capture: nil,
                    sharing: DisplayRuntimeSharingSurfaceState(
                        displayID: displayID,
                        isStarting: false,
                        isActive: true,
                        viewerCount: 3,
                        hasRoute: true
                    ),
                    managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState(
                        configID: configID,
                        serialNumber: 13,
                        desiredEnabled: true,
                        isRunning: true,
                        isLiveRuntime: true,
                        isRebuilding: false,
                        hasRecentApplySuccess: false,
                        hasRebuildFailure: false,
                        hasRestoreFailure: false,
                        modeCount: 1,
                        maximumPixelWidth: 1920,
                        maximumPixelHeight: 1080
                    )
                )
            ],
            catalog: .empty,
            capture: .empty,
            sharing: DisplayRuntimeSharingSnapshot(
                activeSharingDisplayIDs: [displayID],
                startingDisplayIDs: [],
                isSharing: true,
                isWebServiceRunning: true,
                preferredPort: nil,
                sharingClientCount: 3,
                sharingClientCounts: [DisplayRuntimeDisplayClientCount(displayID: displayID, count: 3)],
                lifecycle: DisplayRuntimeSharingLifecycle(
                    phase: .running,
                    requestedPort: nil,
                    boundPort: nil,
                    failureReason: nil,
                    hasFailureMessage: false
                ),
                routes: [DisplayRuntimeShareRoute(displayID: displayID, hasConcreteRoute: true)]
            ),
            virtualDisplay: .empty,
            consumerLeases: [monitorLease, lanLease].map(DisplayRuntimeConsumerLeaseSnapshot.init),
            aggregatedDemands: [
                DisplayRuntimeAggregatedDemand(
                    surfaceIdentity: identity,
                    surfaceEpoch: .initial,
                    resolvedDisplayID: displayID,
                    activeLeaseIDs: [monitorLease.id, lanLease.id],
                    consumerKinds: [.monitor, .lanWebView],
                    effectivePixelSize: DisplayRuntimePixelSize(width: 1920, height: 1080),
                    effectiveFramesPerSecond: 60,
                    capturesCursor: false,
                    qualityProfile: .mixed,
                    powerProfile: .automatic,
                    latencyPreference: .realtime,
                    activeViewerCount: 3,
                    permitsExplicitDowngrade: false
                )
            ],
            effectiveCaptureIntents: [
                DisplayRuntimeEffectiveCaptureIntent(
                    intent: DisplayRuntimeCaptureIntent(
                        surfaceIdentity: identity,
                        surfaceEpoch: .initial,
                        resolvedDisplayID: displayID,
                        aggregateDemand: nil,
                        kind: .capture,
                        reason: .attach,
                        revision: DisplayRuntimeCaptureIntentRevision(rawValue: 7)
                    ),
                    lastApplyResult: .applied(revision: DisplayRuntimeCaptureIntentRevision(rawValue: 7))
                )
            ]
        )

        let presentation = DisplaySurfacePresentationMapper.makePresentation(snapshot: snapshot)
        let surface = try #require(presentation.surfaces.first)

        #expect(surface.title == "Managed Virtual Display")
        #expect(surface.kindText == "Managed virtual")
        #expect(surface.isMonitoring)
        #expect(surface.isSharing)
        #expect(surface.canStopMonitor)
        #expect(surface.canStopLANWebViewSharing)
        #expect(surface.canStopWebService)
        #expect(value("displays_virtual_display_status", in: surface) == "Enabled, Live, Idle")
        #expect(value("displays_monitor_status", in: surface) == "Attached")
        #expect(value("displays_lan_web_view_status", in: surface) == "Attached")
        #expect(value("displays_viewer_count", in: surface) == "3")
        #expect(value("displays_capture_intent_status", in: surface) == "Capture, Attach, Applied")
        #expect(value("displays_lease_status", in: surface) == "2 of 2 active leases")

        let identityText = value("displays_surface_identity_value", in: surface)
        #expect(identityText.hasPrefix("ID hash "))
        #expect(!identityText.contains(configID.uuidString))
        #expect(!identityText.contains(String(displayID)))
    }

    @Test func mapsFailureCodeFromLeaseWithoutEnablingStopActions() {
        let displayID: DisplayRuntimeDisplayID = 77
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: displayID)
        let failedLease = makeLease(
            surfaceIdentity: identity,
            displayID: displayID,
            kind: .monitor,
            state: .failed,
            lastFailureCode: "capture_intent_permission_unavailable"
        )
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                DisplaySurface(
                    identity: identity,
                    kind: .physicalDisplay,
                    currentDisplayID: displayID,
                    isAuxiliary: true,
                    catalog: DisplayRuntimeCatalogSurfaceState(
                        displayID: displayID,
                        isVisible: true,
                        isMain: false,
                        pixelWidth: 1280,
                        pixelHeight: 720,
                        refreshRateMilliHertz: nil,
                        mirrorsDisplayID: nil
                    ),
                    capture: nil,
                    sharing: nil,
                    managedVirtualDisplay: nil
                )
            ],
            catalog: .empty,
            capture: .empty,
            sharing: .empty,
            virtualDisplay: .empty,
            consumerLeases: [DisplayRuntimeConsumerLeaseSnapshot(lease: failedLease)]
        )

        let surface = DisplaySurfacePresentationMapper.makePresentation(snapshot: snapshot).surfaces[0]

        #expect(surface.title == "Physical Auxiliary Display")
        #expect(surface.kindText == "Physical auxiliary")
        #expect(surface.hasFailure)
        #expect(!surface.canStopMonitor)
        #expect(value("displays_monitor_status", in: surface) == "Failed")
        #expect(value("displays_last_failure_code", in: surface) == "capture_intent_permission_unavailable")
        #expect(!value("displays_surface_identity_value", in: surface).contains(String(displayID)))
    }

    @Test func surfaceFactsWithoutRuntimeDemandDoNotEnableControlState() throws {
        let displayID: DisplayRuntimeDisplayID = 78
        let sessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000078"))
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: displayID)
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                DisplaySurface(
                    identity: identity,
                    kind: .physicalDisplay,
                    currentDisplayID: displayID,
                    isAuxiliary: true,
                    catalog: DisplayRuntimeCatalogSurfaceState(
                        displayID: displayID,
                        isVisible: true,
                        isMain: false,
                        pixelWidth: 2560,
                        pixelHeight: 1440,
                        refreshRateMilliHertz: nil,
                        mirrorsDisplayID: nil
                    ),
                    capture: DisplayRuntimeCaptureSurfaceState(
                        displayID: displayID,
                        isStarting: true,
                        sessionIDs: [sessionID],
                        capturesCursor: true,
                        receivedFrameCount: 99
                    ),
                    sharing: DisplayRuntimeSharingSurfaceState(
                        displayID: displayID,
                        isStarting: true,
                        isActive: true,
                        viewerCount: 2,
                        hasRoute: true
                    ),
                    managedVirtualDisplay: nil
                )
            ],
            catalog: .empty,
            capture: DisplayRuntimeCaptureSnapshot(
                startingDisplayIDs: [displayID],
                sessions: [
                    DisplayRuntimeCaptureSession(
                        id: sessionID,
                        displayID: displayID,
                        isVirtualDisplay: false,
                        capturesCursor: true,
                        state: .active,
                        metrics: .init(
                            currentProfile: nil,
                            currentFrameRateTier: nil,
                            receivedFrameCount: 99,
                            profileReconfigurationCount: 0,
                            cursorOverrideReconfigurationCount: 0
                        )
                    )
                ]
            ),
            sharing: DisplayRuntimeSharingSnapshot(
                activeSharingDisplayIDs: [displayID],
                startingDisplayIDs: [displayID],
                isSharing: true,
                isWebServiceRunning: true,
                preferredPort: nil,
                sharingClientCount: 2,
                sharingClientCounts: [
                    DisplayRuntimeDisplayClientCount(displayID: displayID, count: 2)
                ],
                lifecycle: DisplayRuntimeSharingLifecycle(
                    phase: .running,
                    requestedPort: nil,
                    boundPort: nil,
                    failureReason: nil,
                    hasFailureMessage: false
                ),
                routes: [DisplayRuntimeShareRoute(displayID: displayID, hasConcreteRoute: true)]
            ),
            virtualDisplay: .empty,
            consumerLeases: [],
            aggregatedDemands: [],
            effectiveCaptureIntents: []
        )

        let surface = DisplaySurfacePresentationMapper.makePresentation(snapshot: snapshot).surfaces[0]

        #expect(!surface.isMonitoring)
        #expect(!surface.isSharing)
        #expect(!surface.canStopMonitor)
        #expect(!surface.canStopLANWebViewSharing)
        #expect(surface.canStopWebService)
        #expect(value("displays_monitor_status", in: surface) == "Inactive")
        #expect(value("displays_lan_web_view_status", in: surface) == "Route ready")
        #expect(value("displays_viewer_count", in: surface) == "2")
    }

    private func value(
        _ accessibilityIdentifier: String,
        in surface: DisplaySurfacePresentation
    ) -> String {
        surface.statusItems.first {
            $0.accessibilityIdentifier == accessibilityIdentifier
        }?.value ?? ""
    }

    private func makeLease(
        surfaceIdentity: DisplaySurfaceIdentity,
        displayID: DisplayRuntimeDisplayID,
        kind: DisplaySurfaceConsumerKind,
        state: DisplayRuntimeConsumerLeaseState,
        activeViewerCount: Int = 0,
        lastFailureCode: String? = nil
    ) -> DisplayRuntimeConsumerLease {
        DisplayRuntimeConsumerLease(
            surfaceIdentity: surfaceIdentity,
            surfaceEpoch: .initial,
            resolvedDisplayID: displayID,
            kind: kind,
            owner: .init(source: .localUI, redactedLabel: nil),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            state: state,
            demand: DisplayRuntimeConsumerDemand(
                sourcePixelSize: DisplayRuntimePixelSize(width: 1920, height: 1080),
                preferredPixelSize: nil,
                maximumPixelSize: nil,
                sourceFramesPerSecond: 60,
                preferredFramesPerSecond: nil,
                capturesCursor: false,
                powerProfile: .automatic,
                latencyPreference: .realtime,
                activeViewerCount: activeViewerCount
            ),
            lastFailureCode: lastFailureCode
        )
    }
}
