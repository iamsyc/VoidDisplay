@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
@testable import VoidDisplayVirtualDisplay
import Foundation
import Testing

@Suite
struct HomeVirtualDisplayPresentationTests {
    @Test func mapsSummaryAndCardsInConfigOrder() throws {
        let firstID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let secondID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let firstIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: firstID)
        let previewLease = makeLease(
            surfaceIdentity: firstIdentity,
            displayID: 7101,
            kind: .preview,
            state: .attached
        )
        let webViewLease = makeLease(
            surfaceIdentity: firstIdentity,
            displayID: 7101,
            kind: .lanWebView,
            state: .attached,
            activeViewerCount: 2
        )
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                managedSurface(
                    configID: firstID,
                    displayID: 7101,
                    desiredEnabled: true,
                    isRunning: true,
                    isLiveRuntime: true,
                    sharing: DisplayRuntimeSharingSurfaceState(
                        displayID: 7101,
                        isStarting: false,
                        isActive: true,
                        viewerCount: 2,
                        hasRoute: true
                    )
                ),
                managedSurface(
                    configID: secondID,
                    displayID: nil,
                    desiredEnabled: false
                )
            ],
            catalog: .empty,
            capture: .empty,
            sharing: .empty,
            virtualDisplay: .empty,
            consumerLeases: [previewLease, webViewLease].map(DisplayRuntimeConsumerLeaseSnapshot.init),
            aggregatedDemands: [
                DisplayRuntimeAggregatedDemand(
                    surfaceIdentity: firstIdentity,
                    surfaceEpoch: .initial,
                    resolvedDisplayID: 7101,
                    activeLeaseIDs: [previewLease.id, webViewLease.id],
                    consumerKinds: [.preview, .lanWebView],
                    effectivePixelSize: DisplayRuntimePixelSize(width: 1920, height: 1080),
                    effectiveFramesPerSecond: 60,
                    capturesCursor: false,
                    qualityProfile: .mixed,
                    powerProfile: .automatic,
                    latencyPreference: .realtime,
                    activeViewerCount: 2,
                    permitsExplicitDowngrade: false
                )
            ]
        )

        let presentation = HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: snapshot,
            displayConfigs: [
                config(id: firstID, name: "Desk Display", desiredEnabled: true),
                config(id: secondID, name: "Spare Display", desiredEnabled: false)
            ],
            sharePageAddresses: [
                7101: "http://127.0.0.1:18090/display/7101"
            ]
        )

        #expect(presentation.cards.map(\.id) == [firstID, secondID])
        #expect(presentation.cards[0].title == "Desk Display")
        #expect(presentation.cards[0].displayID == 7101)
        #expect(presentation.cards[0].shareAddress == "http://127.0.0.1:18090/display/7101")
        #expect(presentation.cards[0].isRunning)
        #expect(presentation.cards[0].isPreviewing)
        #expect(presentation.cards[0].isSharing)
        #expect(presentation.cards[0].viewerCount == 2)
        #expect(presentation.cards[0].operationalStatusItems.map(\.id) == ["preview", "webView", "viewerCount"])
        #expect(presentation.cards[0].statusLabel == "Enabled · Running")
        #expect(presentation.cards[1].title == "Spare Display")
        #expect(presentation.cards[1].displayID == nil)
        #expect(presentation.cards[1].shareAddress == nil)
        #expect(presentation.cards[1].statusLabel == "Disabled")
        #expect(presentation.summary.virtualDisplayCount == 2)
        #expect(presentation.summary.runningVirtualDisplayCount == 1)
        #expect(presentation.summary.previewingCount == 1)
        #expect(presentation.summary.sharingCount == 1)
        #expect(presentation.summary.activeViewerCount == 2)
    }

    @Test func marksCardsAndSummaryWhenVirtualDisplayNeedsAttention() throws {
        let configID = try #require(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"))
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                managedSurface(
                    configID: configID,
                    displayID: nil,
                    desiredEnabled: true,
                    hasRebuildFailure: true
                )
            ],
            catalog: .empty,
            capture: .empty,
            sharing: .empty,
            virtualDisplay: .empty
        )

        let presentation = HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: snapshot,
            displayConfigs: [config(id: configID, name: "Broken Display", desiredEnabled: true)]
        )

        let card = try #require(presentation.cards.first)
        #expect(card.hasIssue)
        #expect(card.statusLabel == "Enabled · Startup Failed")
        #expect(presentation.summary.recentFailureCount == 1)
        #expect(presentation.summary.lastFailureCode == "virtual_display_rebuild_failed")
    }

    @Test func enabledButStoppedVirtualDisplayDoesNotReadAsRunning() throws {
        let configID = try #require(UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd"))
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                managedSurface(
                    configID: configID,
                    displayID: nil,
                    desiredEnabled: true,
                    isRunning: false,
                    isLiveRuntime: false
                )
            ],
            catalog: .empty,
            capture: .empty,
            sharing: .empty,
            virtualDisplay: .empty
        )

        let presentation = HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: snapshot,
            displayConfigs: [config(id: configID, name: "Stopped Display", desiredEnabled: true)]
        )

        let card = try #require(presentation.cards.first)
        #expect(card.statusLabel == "Enabled · Not Running")
        #expect(!card.isRunning)
        #expect(presentation.summary.runningVirtualDisplayCount == 0)
    }

    @Test func routeOnlyShareAddressKeepsDefaultHomeOperationalStatus() throws {
        let configID = try #require(UUID(uuidString: "12121212-1212-1212-1212-121212121212"))
        let displayID: DisplayRuntimeDisplayID = 7404
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                managedSurface(
                    configID: configID,
                    displayID: displayID,
                    desiredEnabled: true,
                    isRunning: true,
                    isLiveRuntime: true,
                    sharing: DisplayRuntimeSharingSurfaceState(
                        displayID: displayID,
                        isStarting: false,
                        isActive: false,
                        viewerCount: 0,
                        hasRoute: true
                    )
                )
            ],
            catalog: .empty,
            capture: .empty,
            sharing: DisplayRuntimeSharingSnapshot(
                activeSharingDisplayIDs: [],
                startingDisplayIDs: [],
                isSharing: false,
                isWebServiceRunning: true,
                preferredPort: nil,
                sharingClientCount: 0,
                sharingClientCounts: [],
                lifecycle: DisplayRuntimeSharingLifecycle(
                    phase: .running,
                    requestedPort: nil,
                    boundPort: nil,
                    failureReason: nil,
                    hasFailureMessage: false
                ),
                routes: [DisplayRuntimeShareRoute(displayID: displayID, hasConcreteRoute: true)]
            ),
            virtualDisplay: .empty
        )

        let presentation = HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: snapshot,
            displayConfigs: [config(id: configID, name: "Link Ready Display", desiredEnabled: true)],
            sharePageAddresses: [
                displayID: "http://127.0.0.1:18090/display/7404"
            ]
        )

        let card = try #require(presentation.cards.first)
        #expect(card.shareAddress == "http://127.0.0.1:18090/display/7404")
        #expect(card.isSharing == false)
        #expect(card.operationalStatusItems.map(\.id) == ["preview", "webView", "viewerCount"])
        #expect(card.operationalStatusItems.map(\.value) == ["Off", "Off", "0"])
    }

    @Test func summaryIgnoresRuntimeFailuresOutsideCurrentCards() throws {
        let currentID = try #require(UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"))
        let staleID = try #require(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"))
        let staleIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: staleID)
        let staleLease = makeLease(
            surfaceIdentity: staleIdentity,
            displayID: 7202,
            kind: .preview,
            state: .failed,
            lastFailureCode: "stale_lease_failed"
        )
        let revision = DisplayRuntimeCaptureIntentRevision(rawValue: 7)
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                managedSurface(
                    configID: currentID,
                    displayID: nil,
                    desiredEnabled: true
                ),
                managedSurface(
                    configID: staleID,
                    displayID: 7202,
                    desiredEnabled: true,
                    isRunning: true,
                    isLiveRuntime: true,
                    hasRebuildFailure: true
                )
            ],
            catalog: .empty,
            capture: .empty,
            sharing: .empty,
            virtualDisplay: .empty,
            transactions: .init(
                activeTransactions: [],
                recentTransactions: [
                    transactionTrace(
                        configID: staleID,
                        reason: "stale_transaction_failed"
                    )
                ]
            ),
            consumerLeases: [staleLease].map(DisplayRuntimeConsumerLeaseSnapshot.init),
            effectiveCaptureIntents: [
                failedIntent(
                    surfaceIdentity: staleIdentity,
                    revision: revision,
                    failureCode: "stale_intent_failed"
                )
            ]
        )

        let presentation = HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: snapshot,
            displayConfigs: [config(id: currentID, name: "Current Display", desiredEnabled: true)]
        )

        #expect(presentation.summary.virtualDisplayCount == 1)
        #expect(presentation.summary.runningVirtualDisplayCount == 0)
        #expect(presentation.summary.recentFailureCount == 0)
        #expect(presentation.summary.lastFailureCode == nil)
    }

    @Test func summaryReportsSharingLifecycleFailureForCurrentCard() throws {
        let configID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let snapshot = DisplayRuntimeSnapshot(
            surfaces: [
                managedSurface(
                    configID: configID,
                    displayID: 7303,
                    desiredEnabled: true,
                    isRunning: true,
                    isLiveRuntime: true,
                    sharing: DisplayRuntimeSharingSurfaceState(
                        displayID: 7303,
                        isStarting: false,
                        isActive: false,
                        viewerCount: 0,
                        hasRoute: false
                    )
                )
            ],
            catalog: .empty,
            capture: .empty,
            sharing: DisplayRuntimeSharingSnapshot(
                activeSharingDisplayIDs: [],
                startingDisplayIDs: [],
                isSharing: false,
                isWebServiceRunning: false,
                preferredPort: nil,
                sharingClientCount: 0,
                sharingClientCounts: [],
                lifecycle: DisplayRuntimeSharingLifecycle(
                    phase: .failed,
                    requestedPort: nil,
                    boundPort: nil,
                    failureReason: "sharing_lifecycle_failed",
                    hasFailureMessage: true
                ),
                routes: []
            ),
            virtualDisplay: .empty
        )

        let presentation = HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: snapshot,
            displayConfigs: [config(id: configID, name: "Web Display", desiredEnabled: true)]
        )

        let card = try #require(presentation.cards.first)
        #expect(card.hasIssue)
        #expect(presentation.summary.recentFailureCount == 1)
        #expect(presentation.summary.lastFailureCode == "sharing_lifecycle_failed")
    }

    private func config(
        id: UUID,
        name: String,
        desiredEnabled: Bool
    ) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: id,
            displayName: name,
            serialNum: 91,
            physicalWidth: 300,
            physicalHeight: 190,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: desiredEnabled
        )
    }

    private func managedSurface(
        configID: UUID,
        displayID: DisplayRuntimeDisplayID?,
        desiredEnabled: Bool?,
        isRunning: Bool = false,
        isLiveRuntime: Bool = false,
        sharing: DisplayRuntimeSharingSurfaceState? = nil,
        hasRebuildFailure: Bool = false
    ) -> DisplaySurface {
        DisplaySurface(
            identity: .managedVirtualDisplay(configID: configID),
            kind: .managedVirtualDisplay,
            currentDisplayID: displayID,
            isAuxiliary: false,
            catalog: nil,
            capture: nil,
            sharing: sharing,
            managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState(
                configID: configID,
                serialNumber: 91,
                desiredEnabled: desiredEnabled,
                isRunning: isRunning,
                isLiveRuntime: isLiveRuntime,
                isRebuilding: false,
                hasRecentApplySuccess: false,
                hasRebuildFailure: hasRebuildFailure,
                hasRestoreFailure: false,
                modeCount: 1,
                maximumPixelWidth: 1920,
                maximumPixelHeight: 1080
            )
        )
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

    private func failedIntent(
        surfaceIdentity: DisplaySurfaceIdentity,
        revision: DisplayRuntimeCaptureIntentRevision,
        failureCode: String
    ) -> DisplayRuntimeEffectiveCaptureIntent {
        DisplayRuntimeEffectiveCaptureIntent(
            intent: DisplayRuntimeCaptureIntent(
                surfaceIdentity: surfaceIdentity,
                surfaceEpoch: .initial,
                resolvedDisplayID: nil,
                aggregateDemand: nil,
                kind: .capture,
                reason: .attach,
                revision: revision,
                lastFailureCode: failureCode
            ),
            lastApplyResult: .failed(revision: revision, failureCode: failureCode),
            lastFailureCode: failureCode
        )
    }

    private func transactionTrace(
        configID: UUID,
        reason: String
    ) -> DisplayRuntimeTransactionTrace {
        DisplayRuntimeTransactionTrace(
            id: .init(),
            kind: .virtualDisplayRebuild,
            source: .diagnostics,
            status: .failed,
            phases: [.init(phase: .failed)],
            affectedSurfaces: [
                DisplayRuntimeAffectedSurface(
                    identity: .managedVirtualDisplay(configID: configID),
                    configID: configID,
                    preDisplayID: nil,
                    serialNumber: nil,
                    reason: .requestedConfig
                )
            ],
            preSnapshotEvidence: nil,
            postSnapshotEvidence: nil,
            pauseIntents: [],
            restoreIntents: [],
            restoreResults: [],
            failure: DisplayRuntimeTransactionFailure(
                phase: .executingVirtualDisplayCommand,
                reason: reason,
                recoverability: .retryable
            ),
            compensation: .notRequired,
            coalescedRequestCount: 1,
            targetConfigID: configID
        )
    }
}
