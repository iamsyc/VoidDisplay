@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
@testable import VoidDisplayVirtualDisplay
import Foundation
import Testing

@Suite
struct HomeVirtualDisplayStatusTests {
    @Test func mapsManagedVirtualSurfaceStatusWithoutRawIdentity() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000013"))
        let displayID: DisplayRuntimeDisplayID = 4242
        let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let previewLease = makeHomeConsumerLease(
            surfaceIdentity: identity,
            displayID: displayID,
            kind: .preview,
            state: .attached
        )
        let lanLease = makeHomeConsumerLease(
            surfaceIdentity: identity,
            displayID: displayID,
            kind: .lanWebView,
            state: .attached,
            activeViewerCount: 3
        )
        let snapshot = makeHomeRuntimeSnapshot(
            surfaces: [
                managedVirtualSurface(
                    configID: configID,
                    displayID: displayID,
                    desiredEnabled: true,
                    isRunning: true,
                    isLiveRuntime: true,
                    serialNumber: 13,
                    sharing: DisplayRuntimeSharingSurfaceState(
                        displayID: displayID,
                        isStarting: false,
                        isActive: true,
                        viewerCount: 3,
                        hasRoute: true
                    )
                )
            ],
            sharing: sharingSnapshot(displayID: displayID, viewerCount: 3),
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

        let presentation = makePresentation(
            snapshot: snapshot,
            virtualDisplayNamesByConfigID: [configID: "虚拟显示器 13 寸"]
        )
        let surface = try #require(presentation.items.first)

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
        #expect(surface.accessibilitySummary.contains("Web Sharing: Sharing"))
        #expect(surface.accessibilitySummary.contains(SharingConnectionText.status(3)))
        #expect(!surface.accessibilitySummary.contains("Issue:"))
        #expect(surface.viewerCount == 3)
        #expect(!surface.accessibilitySummary.contains(configID.uuidString))
    }

    @Test func hidesCatalogOnlyPhysicalSurfacesFromHomeOverview() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000014"))
        let managedIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let snapshot = makeHomeRuntimeSnapshot(
            surfaces: [
                managedVirtualSurface(
                    configID: configID,
                    desiredEnabled: true,
                    isRunning: true,
                    maximumPixelWidth: 3840,
                    maximumPixelHeight: 2160
                ),
                physicalSurface(
                    displayID: 900,
                    pixelWidth: 1920,
                    pixelHeight: 1080,
                    isMain: true,
                    sharing: DisplayRuntimeSharingSurfaceState(
                        displayID: 900,
                        isStarting: false,
                        isActive: false,
                        viewerCount: 0,
                        hasRoute: true
                    )
                )
            ],
            sharing: sharingSnapshot(displayID: 900, isActive: false, viewerCount: 0),
            consumerLeases: [],
            aggregatedDemands: [],
            effectiveCaptureIntents: []
        )

        let presentation = makePresentation(
            snapshot: snapshot,
            virtualDisplayNamesByConfigID: [configID: "虚拟显示器 14 寸"]
        )

        #expect(presentation.items.map { DisplaySurfaceIdentity.managedVirtualDisplay(configID: $0.id) } == [managedIdentity])
        #expect(presentation.items.first?.title == "虚拟显示器 14 寸")
    }

    @Test(arguments: [
        (enabled: Optional(true), running: true, displayID: Optional<DisplayRuntimeDisplayID>(114), expected: "Enabled · Running"),
        (enabled: Optional(true), running: false, displayID: nil, expected: "Enabled · Not Running"),
        (enabled: Optional(false), running: false, displayID: nil, expected: "Disabled"),
        (enabled: nil, running: false, displayID: nil, expected: "Configuration Missing")
    ])
    func managedVirtualDisplayStatusReflectsConfigurationAndRuntime(
        state: (enabled: Bool?, running: Bool, displayID: DisplayRuntimeDisplayID?, expected: String)
    ) throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000114"))
        let surface = managedVirtualSurface(
            configID: configID,
            displayID: state.displayID,
            desiredEnabled: state.enabled,
            isRunning: state.running,
            isLiveRuntime: state.running
        )
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface)
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == state.expected)
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
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, activeTransactions: [trace])
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Starting")
    }

    @Test func managedVirtualDisplayStatusShowsStartingForActiveEditRebuild() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000121"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: true)
        let trace = transactionTrace(
            kind: .virtualDisplayEditRebuild,
            status: .active,
            targetConfigID: configID
        )
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, activeTransactions: [trace])
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Starting")
    }

    @Test func managedVirtualDisplayStatusDerivesRebuildFailureFromTransaction() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000122"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: true)
        let trace = transactionTrace(
            kind: .virtualDisplayRebuild,
            status: .failed,
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "virtual_display_rebuild_failed",
                underlyingDomain: "VirtualDisplay",
                underlyingCode: 1,
                recoverability: .retryable
            ),
            targetConfigID: configID
        )
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, recentTransactions: [trace])
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Startup Failed")
        #expect(compactValue("displays_issue_status", in: item) == "Startup Failed")
    }

    @Test func managedVirtualDisplayStatusIgnoresOlderRebuildFailureAfterNewerSuccess() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let surface = managedVirtualSurface(
            configID: configID,
            displayID: 123,
            desiredEnabled: true,
            isRunning: true,
            isLiveRuntime: true
        )
        let olderFailure = transactionTrace(
            kind: .virtualDisplayRebuild,
            status: .failed,
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "virtual_display_rebuild_failed",
                underlyingDomain: "VirtualDisplay",
                underlyingCode: 1,
                recoverability: .retryable
            ),
            targetConfigID: configID
        )
        let newerSuccess = transactionTrace(
            kind: .virtualDisplayRebuild,
            status: .completed,
            targetConfigID: configID
        )
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(
                surface: surface,
                recentTransactions: [newerSuccess, olderFailure]
            )
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Running")
        #expect(compactValue("displays_issue_status", in: item).isEmpty)
    }

    @Test func managedVirtualDisplayStatusIgnoresFailedDisableTransaction() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000125"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: true)
        let failedDisable = transactionTrace(
            kind: .virtualDisplayDisable,
            status: .failed,
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "virtual_display_disable_failed",
                underlyingDomain: "VirtualDisplay",
                underlyingCode: 1,
                recoverability: .retryable
            ),
            targetConfigID: configID
        )
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, recentTransactions: [failedDisable])
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Not Running")
        #expect(compactValue("displays_issue_status", in: item).isEmpty)
    }

    @Test func managedVirtualDisplayRunningStateOverridesStaleRestoreFailure() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000126"))
        let surface = managedVirtualSurface(
            configID: configID,
            displayID: 126,
            desiredEnabled: true,
            isRunning: true,
            isLiveRuntime: true,
            hasRestoreFailure: true
        )
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface)
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Running")
        #expect(compactValue("displays_issue_status", in: item).isEmpty)
    }

    @Test func managedVirtualDisplayStatusShowsRetryingOverOlderRebuildFailure() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000124"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: true)
        let activeRetry = transactionTrace(
            kind: .virtualDisplayRebuild,
            status: .active,
            targetConfigID: configID
        )
        let olderFailure = transactionTrace(
            kind: .virtualDisplayRebuild,
            status: .failed,
            failure: .init(
                phase: .executingVirtualDisplayCommand,
                reason: "virtual_display_rebuild_failed",
                underlyingDomain: "VirtualDisplay",
                underlyingCode: 1,
                recoverability: .retryable
            ),
            targetConfigID: configID
        )
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(
                surface: surface,
                activeTransactions: [activeRetry],
                recentTransactions: [olderFailure]
            )
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Starting")
        #expect(compactValue("displays_issue_status", in: item).isEmpty)
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
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, recentTransactions: [trace])
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Startup Failed")
        #expect(compactValue("displays_issue_status", in: item) == "Startup Failed")
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
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(surface: surface, recentTransactions: [newerSuccess, olderFailure])
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Running")
        #expect(compactValue("displays_issue_status", in: item).isEmpty)
    }

    @Test func managedVirtualDisplayStatusIgnoresOlderStartupFailureAfterManualEnableSuccess() throws {
        let configID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000127"))
        let surface = managedVirtualSurface(configID: configID, desiredEnabled: true)
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
            kind: .virtualDisplayEnable,
            status: .completed,
            targetConfigID: configID
        )
        let presentation = makePresentation(
            snapshot: managedVirtualSnapshot(
                surface: surface,
                recentTransactions: [newerSuccess, olderFailure]
            )
        )

        let item = try #require(presentation.items.first)
        #expect(compactValue("displays_virtual_display_status", in: item) == "Enabled · Not Running")
        #expect(compactValue("displays_issue_status", in: item).isEmpty)
    }

    @Test func managedDisplayFailureUsesLeaseStatus() throws {
        let displayID: DisplayRuntimeDisplayID = 77
        let configID = UUID()
        let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let failedLease = makeHomeConsumerLease(
            surfaceIdentity: identity,
            displayID: displayID,
            kind: .preview,
            state: .failed,
            lastFailureCode: "capture_intent_permission_unavailable"
        )
        let snapshot = makeHomeRuntimeSnapshot(
            surfaces: [
                managedVirtualSurface(configID: configID, displayID: displayID, desiredEnabled: true, maximumPixelWidth: 1280, maximumPixelHeight: 720)
            ],
            consumerLeases: [DisplayRuntimeConsumerLeaseSnapshot(lease: failedLease)]
        )

        let surface = makePresentation(snapshot: snapshot).items[0]

        #expect(compactValue("displays_preview_status", in: surface) == "Failed")
        #expect(compactValue("displays_issue_status", in: surface) == "Failed")
    }

    @Test func captureFactsWithoutRuntimeDemandRemainOff() throws {
        let configID = UUID()
        let displayID: DisplayRuntimeDisplayID = 78
        let sessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000078"))
        let snapshot = makeHomeRuntimeSnapshot(
            surfaces: [
                managedVirtualSurface(
                    configID: configID,
                    displayID: displayID,
                    desiredEnabled: true,
                    maximumPixelWidth: 2560,
                    maximumPixelHeight: 1440,
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
                    )
                )
            ],
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
            sharing: sharingSnapshot(displayID: displayID, isStarting: true, viewerCount: 2),
            consumerLeases: [],
            aggregatedDemands: [],
            effectiveCaptureIntents: []
        )

        let surface = makePresentation(snapshot: snapshot).items[0]

        #expect(!surface.isPreviewing)
        #expect(!surface.isSharing)
        #expect(compactValue("displays_preview_status", in: surface) == "Off")
        #expect(compactValue("displays_lan_web_view_status", in: surface) == "Off")
        #expect(compactValue("displays_viewer_count", in: surface) == "2")
    }

    @Test func effectiveIntentRuntimeDemandDrivesStatus() throws {
        let displayID: DisplayRuntimeDisplayID = 79
        let configID = UUID()
        let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
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
        let snapshot = makeHomeRuntimeSnapshot(
            surfaces: [
                managedVirtualSurface(configID: configID, displayID: displayID, desiredEnabled: true, maximumPixelWidth: 2560, maximumPixelHeight: 1440)
            ],
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

        let surface = makePresentation(snapshot: snapshot).items[0]

        #expect(surface.isPreviewing)
        #expect(surface.isSharing)
        #expect(compactValue("displays_preview_status", in: surface) == "Previewing")
        #expect(compactValue("displays_lan_web_view_status", in: surface) == "Sharing")
    }

    private func makePresentation(
        snapshot: DisplayRuntimeSnapshot,
        virtualDisplayNamesByConfigID: [UUID: String] = [:]
    ) -> HomeVirtualDisplaySurfacePresentation {
        let configs = snapshot.surfaces.compactMap { surface -> VirtualDisplayConfig? in
            guard let state = surface.managedVirtualDisplay else { return nil }
            return VirtualDisplayConfig(
                id: state.configID,
                displayName: virtualDisplayNamesByConfigID[state.configID] ?? "Virtual Display",
                serialNum: state.serialNumber ?? 14,
                physicalWidth: 300,
                physicalHeight: 190,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: state.desiredEnabled ?? false
            )
        }
        return HomeVirtualDisplayPresentationMapper.makePresentation(snapshot: snapshot, displayConfigs: configs)
    }

    private func compactIDs(in surface: HomeVirtualDisplayItemPresentation) -> [String] {
        surface.compactStatusItems.map(\.id)
    }

    private func compactValue(_ identifier: String, in surface: HomeVirtualDisplayItemPresentation) -> String {
        surface.compactStatusItems.first { $0.accessibilityIdentifier == identifier }?.value ?? ""
    }

    private func physicalSurface(
        displayID: DisplayRuntimeDisplayID,
        pixelWidth: Int,
        pixelHeight: Int,
        isMain: Bool = false,
        capture: DisplayRuntimeCaptureSurfaceState? = nil,
        sharing: DisplayRuntimeSharingSurfaceState? = nil
    ) -> DisplaySurface {
        DisplaySurface(
            identity: .physicalDisplay(displayID: displayID),
            kind: .physicalDisplay,
            currentDisplayID: displayID,
            isAuxiliary: true,
            catalog: DisplayRuntimeCatalogSurfaceState(
                displayID: displayID,
                isVisible: true,
                isMain: isMain,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                refreshRateMilliHertz: nil,
                mirrorsDisplayID: nil
            ),
            capture: capture,
            sharing: sharing,
            managedVirtualDisplay: nil
        )
    }

    private func sharingSnapshot(
        displayID: DisplayRuntimeDisplayID,
        isActive: Bool = true,
        isStarting: Bool = false,
        viewerCount: Int
    ) -> DisplayRuntimeSharingSnapshot {
        DisplayRuntimeSharingSnapshot(
            activeSharingDisplayIDs: isActive ? [displayID] : [],
            startingDisplayIDs: isStarting ? [displayID] : [],
            isSharing: isActive,
            isWebServiceRunning: true,
            preferredPort: nil,
            sharingClientCount: viewerCount,
            sharingClientCounts: isActive ? [.init(displayID: displayID, count: viewerCount)] : [],
            lifecycle: .init(
                phase: .running,
                requestedPort: nil,
                boundPort: nil,
                failureReason: nil,
                hasFailureMessage: false
            ),
            routes: [.init(displayID: displayID, hasConcreteRoute: true)]
        )
    }

    private func managedVirtualSnapshot(
        surface: DisplaySurface,
        activeTransactions: [DisplayRuntimeTransactionTrace] = [],
        recentTransactions: [DisplayRuntimeTransactionTrace] = []
    ) -> DisplayRuntimeSnapshot {
        makeHomeRuntimeSnapshot(
            surfaces: [surface],
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
        hasRestoreFailure: Bool = false,
        serialNumber: UInt32 = 14,
        maximumPixelWidth: Int = 1920,
        maximumPixelHeight: Int = 1080,
        capture: DisplayRuntimeCaptureSurfaceState? = nil,
        sharing: DisplayRuntimeSharingSurfaceState? = nil
    ) -> DisplaySurface {
        DisplaySurface(
            identity: .managedVirtualDisplay(configID: configID),
            kind: .managedVirtualDisplay,
            currentDisplayID: displayID,
            isAuxiliary: false,
            catalog: nil,
            capture: capture,
            sharing: sharing,
            managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState(
                configID: configID,
                serialNumber: serialNumber,
                desiredEnabled: desiredEnabled,
                isRunning: isRunning,
                isLiveRuntime: isLiveRuntime,
                hasRestoreFailure: hasRestoreFailure,
                modeCount: 1,
                maximumPixelWidth: maximumPixelWidth,
                maximumPixelHeight: maximumPixelHeight
            )
        )
    }

    private func transactionTrace(
        kind: DisplayRuntimeTransactionKind,
        status: DisplayRuntimeTransactionStatus,
        failure: DisplayRuntimeTransactionFailure? = nil,
        startupRestoreIntent: DisplayRuntimeStartupRestoreIntent? = nil,
        startupRestoreCommandResult: DisplayRuntimeStartupRestoreCommandTrace? = nil,
        targetConfigID: UUID? = nil
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
            targetConfigID: targetConfigID,
            startupRestoreIntent: startupRestoreIntent,
            startupRestoreCommandResult: startupRestoreCommandResult
        )
    }
}
