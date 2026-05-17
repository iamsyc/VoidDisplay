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
        let previewLease = makeLease(
            surfaceIdentity: identity,
            displayID: displayID,
            kind: .preview,
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
            consumerLeases: [previewLease, lanLease].map(DisplayRuntimeConsumerLeaseSnapshot.init),
            aggregatedDemands: [
                DisplayRuntimeAggregatedDemand(
                    surfaceIdentity: identity,
                    surfaceEpoch: .initial,
                    resolvedDisplayID: displayID,
                    activeLeaseIDs: [previewLease.id, lanLease.id],
                    consumerKinds: [.preview, .lanWebView],
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

        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: snapshot,
            virtualDisplayNamesByConfigID: [configID: "虚拟显示器 13 寸"]
        )
        let surface = try #require(presentation.surfaces.first)

        #expect(surface.title == "虚拟显示器 13 寸")
        #expect(surface.isPreviewing)
        #expect(surface.isSharing)
        #expect(compactIDs(in: surface) == [
            "virtualDisplay",
            "preview",
            "webView",
            "viewerCount"
        ])
        #expect(!compactIDs(in: surface).contains("kind"))
        #expect(!compactIDs(in: surface).contains("resolution"))
        #expect(compactValue("displays_virtual_display_status", in: surface) == "Enabled · Running")
        #expect(compactValue("displays_preview_status", in: surface) == "Previewing")
        #expect(compactValue("displays_lan_web_view_status", in: surface) == "Sharing")
        #expect(compactValue("displays_viewer_count", in: surface) == "3")
        #expect(compactValue("displays_issue_status", in: surface).isEmpty)
        #expect(surface.accessibilitySummary.contains("Preview: Previewing"))
        #expect(surface.accessibilitySummary.contains("Web View: Sharing"))
        #expect(surface.accessibilitySummary.contains("Viewers: 3"))
        #expect(!surface.accessibilitySummary.contains("Issue:"))
        let stopPreviewAction = try #require(rowAction(.stopPreview, in: surface))
        #expect(stopPreviewAction.title == "Stop")
        #expect(stopPreviewAction.help == "Stop Preview")
        #expect(stopPreviewAction.isEnabled)
        let stopLANWebViewAction = try #require(rowAction(.stopLANWebView, in: surface))
        #expect(stopLANWebViewAction.title == "Stop")
        #expect(stopLANWebViewAction.help == "Stop Web View")
        #expect(stopLANWebViewAction.isEnabled)
        #expect(technicalValue("displays_capture_state_status", in: surface) == "Capture, Attach, Applied")
        #expect(technicalValue("displays_lease_status", in: surface) == "2 of 2 active")
        #expect(technicalValue("displays_last_failure_code", in: surface) == "None")

        let identityText = technicalValue("displays_surface_identity_value", in: surface)
        #expect(identityText.hasPrefix("ID hash "))
        #expect(!identityText.contains(configID.uuidString))
        #expect(!identityText.contains(String(displayID)))
        #expect(!surface.accessibilitySummary.contains(configID.uuidString))
        #expect(technicalTitles(in: surface) == [
            "Display Identifier",
            "Capture State",
            "Runtime Attachment",
            "Diagnostic Code"
        ])
    }

    @Test func hidesCatalogOnlyPhysicalSurfacesFromHomeOverview() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000014"))
        let managedIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let physicalIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 900)
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                DisplaySurface(
                    identity: managedIdentity,
                    kind: .managedVirtualDisplay,
                    currentDisplayID: nil,
                    isAuxiliary: false,
                    catalog: nil,
                    capture: nil,
                    sharing: nil,
                    managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState(
                        configID: configID,
                        serialNumber: 14,
                        desiredEnabled: true,
                        isRunning: true,
                        isLiveRuntime: false,
                        isRebuilding: false,
                        hasRecentApplySuccess: false,
                        hasRebuildFailure: false,
                        hasRestoreFailure: false,
                        modeCount: 1,
                        maximumPixelWidth: 3840,
                        maximumPixelHeight: 2160
                    )
                ),
                DisplaySurface(
                    identity: physicalIdentity,
                    kind: .physicalDisplay,
                    currentDisplayID: 900,
                    isAuxiliary: true,
                    catalog: DisplayRuntimeCatalogSurfaceState(
                        displayID: 900,
                        isVisible: true,
                        isMain: true,
                        pixelWidth: 1920,
                        pixelHeight: 1080,
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
            consumerLeases: [],
            aggregatedDemands: [],
            effectiveCaptureIntents: []
        )

        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: snapshot,
            virtualDisplayNamesByConfigID: [configID: "虚拟显示器 14 寸"]
        )

        #expect(presentation.surfaces.map(\.surfaceIdentity) == [managedIdentity])
        #expect(presentation.surfaces.first?.title == "虚拟显示器 14 寸")
        #expect(presentation.surfaces.first?.subtitle == "3840 × 2160 pixels")
    }

    @Test func managedVirtualDisplayStatusSeparatesConfigurationAndRunningState() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000114"))
        let surface = managedVirtualSurface(
            configID: configID,
            displayID: 114,
            desiredEnabled: true,
            isRunning: true,
            isLiveRuntime: true
        )
        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface)
        )

        let item = try #require(presentation.surfaces.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Running")
    }

    @Test func managedVirtualDisplayStatusShowsStartingForActiveStartupRestore() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000115"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: true)
        let trace = transactionTrace(
            kind: .virtualDisplayStartupRestore,
            status: .active,
            startupRestoreIntent: DisplayRuntimeStartupRestoreIntent(
                runID: .init(rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000215"))),
                configID: configID,
                configEvidence: .init(
                    id: configID,
                    serialNumber: 15,
                    desiredEnabled: true,
                    physicalWidthMillimeters: 300,
                    physicalHeightMillimeters: 200,
                    modeCount: 1,
                    maximumPixelWidth: 1920,
                    maximumPixelHeight: 1080
                )
            )
        )
        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, activeTransactions: [trace])
        )

        let item = try #require(presentation.surfaces.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Starting")
    }

    @Test func managedVirtualDisplayStatusShowsStartupFailureForRecentStartupFailure() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000116"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: true)
        let trace = transactionTrace(
            kind: .virtualDisplayStartupRestore,
            status: .failed,
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "startup_restore_lower_command_failed",
                underlyingDomain: "CGVirtualDisplay",
                underlyingCode: -1,
                recoverability: .retryable
            ),
            startupRestoreCommandResult: .init(
                configID: configID,
                preDisplayID: nil,
                postDisplayID: nil,
                restoreOutcome: .failed,
                didProduceVerifiableSideEffect: false,
                failureReason: "startup_restore_lower_command_failed",
                underlyingDomain: "CGVirtualDisplay",
                underlyingCode: -1,
                compensationOutcome: .notAttempted,
                compensationFailureReason: nil
            )
        )
        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, recentTransactions: [trace])
        )

        let item = try #require(presentation.surfaces.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Could Not Start")
        #expect(compactValue("displays_issue_status", in: item) == "Needs attention")
    }

    @Test func managedVirtualDisplayStatusIgnoresOlderStartupFailureAfterNewerStartupSuccess() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000119"))
        let surface = managedVirtualSurface(
            configID: configID,
            displayID: 119,
            desiredEnabled: true,
            isRunning: true,
            isLiveRuntime: true
        )
        let olderFailure = transactionTrace(
            kind: .virtualDisplayStartupRestore,
            status: .failed,
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "startup_restore_lower_command_failed",
                underlyingDomain: "CGVirtualDisplay",
                underlyingCode: -1,
                recoverability: .retryable
            ),
            startupRestoreCommandResult: .init(
                configID: configID,
                preDisplayID: nil,
                postDisplayID: nil,
                restoreOutcome: .failed,
                didProduceVerifiableSideEffect: false,
                failureReason: "startup_restore_lower_command_failed",
                underlyingDomain: "CGVirtualDisplay",
                underlyingCode: -1,
                compensationOutcome: .notAttempted,
                compensationFailureReason: nil
            )
        )
        let newerSuccess = transactionTrace(
            kind: .virtualDisplayStartupRestore,
            status: .completed,
            startupRestoreCommandResult: .init(
                configID: configID,
                preDisplayID: nil,
                postDisplayID: 119,
                restoreOutcome: .succeeded,
                didProduceVerifiableSideEffect: true,
                failureReason: nil,
                underlyingDomain: nil,
                underlyingCode: nil,
                compensationOutcome: .notAttempted,
                compensationFailureReason: nil
            )
        )
        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, recentTransactions: [newerSuccess, olderFailure])
        )

        let item = try #require(presentation.surfaces.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Running")
        #expect(compactValue("displays_issue_status", in: item).isEmpty)
    }

    @Test func managedVirtualDisplayStatusShowsNotRunningWithoutFailureEvidence() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000117"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: true)
        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface)
        )

        let item = try #require(presentation.surfaces.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Not Running")
    }

    @Test func managedVirtualDisplayStatusHidesRuntimeStateWhenDisabled() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000118"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: false)
        let presentation = DisplaySurfacePresentationMapper.makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface)
        )

        let item = try #require(presentation.surfaces.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Disabled")
    }

    @Test func mapsFailureCodeFromLeaseWithoutEnablingStopActions() throws {
        let displayID: DisplayRuntimeDisplayID = 77
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: displayID)
        let failedLease = makeLease(
            surfaceIdentity: identity,
            displayID: displayID,
            kind: .preview,
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

        #expect(surface.title == "Physical Display")
        #expect(compactValue("displays_virtual_display_status", in: surface).isEmpty)
        #expect(compactValue("displays_preview_status", in: surface) == "Failed")
        #expect(compactValue("displays_issue_status", in: surface) == "Needs attention")
        let openPreviewAction = try #require(rowAction(.openPreview, in: surface))
        #expect(openPreviewAction.isEnabled)
        #expect(rowAction(.stopPreview, in: surface) == nil)
        #expect(technicalValue("displays_last_failure_code", in: surface) == "capture_intent_permission_unavailable")
        #expect(!technicalValue("displays_surface_identity_value", in: surface).contains(String(displayID)))
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

        #expect(!surface.isPreviewing)
        #expect(!surface.isSharing)
        #expect(compactValue("displays_preview_status", in: surface) == "Off")
        #expect(compactValue("displays_lan_web_view_status", in: surface) == "Route Ready")
        #expect(compactValue("displays_viewer_count", in: surface) == "2")
        let openPreviewAction = try #require(rowAction(.openPreview, in: surface))
        #expect(openPreviewAction.isEnabled)
        let openLANWebViewAction = try #require(rowAction(.openLANWebView, in: surface))
        #expect(openLANWebViewAction.title == "Web View")
        #expect(openLANWebViewAction.help == "Open Web View")
        #expect(openLANWebViewAction.isEnabled)
        #expect(rowAction(.stopPreview, in: surface) == nil)
        #expect(rowAction(.stopLANWebView, in: surface) == nil)
    }

    @Test func effectiveIntentRuntimeDemandDrivesAttachedStateWithoutStopActions() throws {
        let displayID: DisplayRuntimeDisplayID = 79
        let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: displayID)
        let aggregateDemand = DisplayRuntimeAggregatedDemand(
            surfaceIdentity: identity,
            surfaceEpoch: .initial,
            resolvedDisplayID: displayID,
            activeLeaseIDs: [],
            consumerKinds: [.preview, .lanWebView],
            effectivePixelSize: DisplayRuntimePixelSize(width: 2560, height: 1440),
            effectiveFramesPerSecond: 60,
            capturesCursor: false,
            qualityProfile: .mixed,
            powerProfile: .automatic,
            latencyPreference: .realtime,
            activeViewerCount: 4,
            permitsExplicitDowngrade: false
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
                        pixelWidth: 2560,
                        pixelHeight: 1440,
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
            consumerLeases: [],
            aggregatedDemands: [],
            effectiveCaptureIntents: [
                DisplayRuntimeEffectiveCaptureIntent(
                    intent: DisplayRuntimeCaptureIntent(
                        surfaceIdentity: identity,
                        surfaceEpoch: .initial,
                        resolvedDisplayID: displayID,
                        aggregateDemand: aggregateDemand,
                        kind: .capture,
                        reason: .attach,
                        revision: DisplayRuntimeCaptureIntentRevision(rawValue: 8)
                    ),
                    lastApplyResult: .applied(revision: DisplayRuntimeCaptureIntentRevision(rawValue: 8))
                )
            ]
        )

        let surface = DisplaySurfacePresentationMapper.makePresentation(snapshot: snapshot).surfaces[0]

        #expect(surface.isPreviewing)
        #expect(surface.isSharing)
        #expect(compactValue("displays_preview_status", in: surface) == "Previewing")
        #expect(compactValue("displays_lan_web_view_status", in: surface) == "Sharing")
        let stopPreviewAction = try #require(rowAction(.stopPreview, in: surface))
        #expect(!stopPreviewAction.isEnabled)
        let stopLANWebViewAction = try #require(rowAction(.stopLANWebView, in: surface))
        #expect(!stopLANWebViewAction.isEnabled)
        #expect(technicalValue("displays_capture_state_status", in: surface) == "Capture, Attach, Applied")
        #expect(technicalValue("displays_lease_status", in: surface) == "No attachments")
    }

    private func compactIDs(in surface: DisplaySurfacePresentation) -> [String] {
        surface.compactStatusItems.map(\.id)
    }

    private func rowAction(
        _ kind: DisplaySurfaceRowActionKind,
        in surface: DisplaySurfacePresentation
    ) -> DisplaySurfaceRowActionPresentation? {
        surface.rowActions.first { $0.kind == kind }
    }

    private func compactValue(
        _ accessibilityIdentifier: String,
        in surface: DisplaySurfacePresentation
    ) -> String {
        value(accessibilityIdentifier, in: surface.compactStatusItems)
    }

    private func technicalValue(
        _ accessibilityIdentifier: String,
        in surface: DisplaySurfacePresentation
    ) -> String {
        value(accessibilityIdentifier, in: surface.technicalStatusItems)
    }

    private func value(
        _ accessibilityIdentifier: String,
        in items: [DisplaySurfaceStatusItemPresentation]
    ) -> String {
        items.first {
            $0.accessibilityIdentifier == accessibilityIdentifier
        }?.value ?? ""
    }

    private func technicalTitles(in surface: DisplaySurfacePresentation) -> [String] {
        surface.technicalStatusItems.map(\.title)
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

    private func managedVirtualSnapshot(
        surface: DisplaySurface,
        activeTransactions: [DisplayRuntimeTransactionTrace] = [],
        recentTransactions: [DisplayRuntimeTransactionTrace] = []
    ) -> DisplayRuntimeSnapshot {
        DisplayRuntimeSnapshot(
            surfaces: [surface],
            catalog: .empty,
            capture: .empty,
            sharing: .empty,
            virtualDisplay: .empty,
            transactions: .init(
                activeTransactions: activeTransactions,
                recentTransactions: recentTransactions
            )
        )
    }

    private func managedVirtualSurface(
        configID: UUID,
        displayID: DisplayRuntimeDisplayID? = nil,
        desiredEnabled: Bool?,
        isRunning: Bool = false,
        isLiveRuntime: Bool = false,
        isRebuilding: Bool = false,
        hasRebuildFailure: Bool = false,
        hasRestoreFailure: Bool = false
    ) -> DisplaySurface {
        DisplaySurface(
            identity: .managedVirtualDisplay(configID: configID),
            kind: .managedVirtualDisplay,
            currentDisplayID: displayID,
            isAuxiliary: false,
            catalog: nil,
            capture: nil,
            sharing: nil,
            managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState(
                configID: configID,
                serialNumber: 14,
                desiredEnabled: desiredEnabled,
                isRunning: isRunning,
                isLiveRuntime: isLiveRuntime,
                isRebuilding: isRebuilding,
                hasRecentApplySuccess: false,
                hasRebuildFailure: hasRebuildFailure,
                hasRestoreFailure: hasRestoreFailure,
                modeCount: 1,
                maximumPixelWidth: 1920,
                maximumPixelHeight: 1080
            )
        )
    }

    private func transactionTrace(
        kind: DisplayRuntimeTransactionKind,
        status: DisplayRuntimeTransactionStatus,
        failure: DisplayRuntimeTransactionFailure? = nil,
        startupRestoreIntent: DisplayRuntimeStartupRestoreIntent? = nil,
        startupRestoreCommandResult: DisplayRuntimeStartupRestoreCommandTrace? = nil
    ) -> DisplayRuntimeTransactionTrace {
        DisplayRuntimeTransactionTrace(
            id: .init(),
            kind: kind,
            source: .startup,
            status: status,
            phases: [],
            affectedSurfaces: [],
            preSnapshotEvidence: nil,
            postSnapshotEvidence: nil,
            pauseIntents: [],
            restoreIntents: [],
            restoreResults: [],
            failure: failure,
            compensation: .notRequired,
            coalescedRequestCount: 1,
            startupRestoreIntent: startupRestoreIntent,
            startupRestoreCommandResult: startupRestoreCommandResult
        )
    }
}
